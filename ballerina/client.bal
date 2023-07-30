// Copyright (c) 2022 WSO2 Inc. (http://www.wso2.org) All Rights Reserved.
//
// WSO2 Inc. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/jballerina.java;
import ballerina/uuid;
import ballerina/http;
import ballerina/websocket;

const HTTP = "http://";
const HTTPS = "https://";
const WS = "ws://";
const WSS = "wss://";

# The Ballerina GraphQL client that can be used to communicate with GraphQL APIs.
public isolated client class Client {
    private final http:Client httpClient;
    private final string wsServiceUrl;
    private websocket:Client? wsClient = ();
    private websocket:ClientConfiguration wsConfig;

    private final map<Subscriber> subscribersMap = {};
    private boolean subscriptionStarted = false;
    private boolean wsConnectionInit = false;
    private boolean wsConnectionClosed = false;

    # Gets invoked to initialize the `connector`.
    #
    # + serviceUrl - URL of the target service
    # + clientConfig - The configurations to be used when initializing the `connector`
    # + return - An error at the failure of client initialization
    public isolated function init(string serviceUrl, *ClientConfiguration clientConfig) returns ClientError? {
        http:ClientConfiguration httpClientConfig = {
            http1Settings: clientConfig.http1Settings,
            timeout: clientConfig.timeout,
            forwarded: clientConfig.forwarded,
            followRedirects: clientConfig.followRedirects,
            poolConfig: clientConfig.poolConfig,
            cache: clientConfig.cache,
            compression: clientConfig.compression,
            auth: clientConfig.auth,
            circuitBreaker: clientConfig.circuitBreaker,
            retryConfig: clientConfig.retryConfig,
            cookieConfig: clientConfig.cookieConfig,
            responseLimits: clientConfig.responseLimits,
            secureSocket: clientConfig.secureSocket,
            proxy: clientConfig.proxy,
            validation: clientConfig.validation
        };
        httpClientConfig.httpVersion = http:HTTP_1_1;
        http:Client|http:ClientError httpClient = new (serviceUrl, httpClientConfig);
        if httpClient is http:ClientError {
            return error HttpError("GraphQL Client Error", httpClient, body = ());
        }
        self.httpClient = httpClient;
        self.wsServiceUrl = getServiceUrlWithWsScheme(serviceUrl, clientConfig.websocketConfig);
        var {pingPongHandler, ...rest} = clientConfig.websocketConfig;
        self.wsConfig = {pingPongHandler, ...rest.clone()};
    }

    # Executes a GraphQL document and data binds the GraphQL response to a record with data and extensions
    # which is a subtype of GenericResponse.
    #
    # + document - The GraphQL document. It can include queries & mutations.
    # For example `query OperationName($code:ID!) {country(code:$code) {name}}`.
    # + variables - The GraphQL variables. For example `{"code": "<variable_value>"}`.
    # + operationName - The GraphQL operation name. If a request has two or more operations, then each operation must have a name.
    # A request can only execute one operation, so you must also include the operation name to execute.
    # + headers - The GraphQL API headers to execute each query
    # + targetType - The payload, which is expected to be returned after data binding. For example
    # `type CountryByCodeResponse record {| map<json?> extensions?; record {| record{|string name;|}? country; |} data;`
    # + return - The GraphQL response or a `graphql:ClientError` if failed to execute the query
    # # Deprecated
    # This method is now deprecated. Use the `execute()` API instead
    @deprecated
    remote isolated function executeWithType(string document, map<anydata>? variables = (), string? operationName = (),
            map<string|string[]>? headers = (),
            typedesc<GenericResponse|record {}|json> targetType = <>)
                                            returns targetType|ClientError = @java:Method {
        'class: "io.ballerina.stdlib.graphql.runtime.client.QueryExecutor",
        name: "executeWithType"
    } external;

    # Executes a GraphQL document and data binds the GraphQL response to a record with data, extensions and errors
    # which is a subtype of GenericResponseWithErrors.
    #
    # + document - The GraphQL document. It can include queries & mutations.
    # For example `query countryByCode($code:ID!) {country(code:$code) {name}}`.
    # + variables - The GraphQL variables. For example `{"code": "<variable_value>"}`.
    # + operationName - The GraphQL operation name. If a request has two or more operations, then each operation must have a name.
    # A request can only execute one operation, so you must also include the operation name to execute.
    # + headers - The GraphQL API headers to execute each query
    # + targetType - The payload (`GenericResponseWithErrors`), which is expected to be returned after data binding. For example
    # `type CountryByCodeResponse record {| map<json?> extensions?; record {| record{|string name;|}? country; |} data; ErrorDetail[] errors?; |};`
    # + return - The GraphQL response or a `graphql:ClientError` if failed to execute the query
    remote isolated function execute(string document, map<anydata>? variables = (), string? operationName = (),
            map<string|string[]>? headers = (),
            typedesc<GenericResponseWithErrors|record {}|json|stream<GenericResponseWithErrors|record {}|json>> targetType = <>)
                                    returns targetType|ClientError = @java:Method {
        'class: "io.ballerina.stdlib.graphql.runtime.client.QueryExecutor",
        name: "execute"
    } external;

    # Closes the underlying WebSocket connection of all the subscriptions.
    #
    # + return - A `graphql:ClientError` if an error occurred while closing the connection
    remote isolated function closeSubscriptions() returns ClientError? {
        do {
            lock {
                if self.wsConnectionClosed {
                    return;
                }
            }
            lock {
                foreach Subscriber subscriber in self.subscribersMap {
                    check subscriber->unsubscribe();

                }
            }
            websocket:Client wsClient = check self.getWebSocketClient();
            check wsClient->close();
            lock {
                self.wsConnectionClosed = true;
            }
        } on fail error err {
            return error ClientError(string `Failed to close WebSocket connection: ${err.message()}`, err.cause());
        }
    }

    private isolated function processExecuteWithType(typedesc<GenericResponse|record {}|json> targetType,
            string document, map<anydata>? variables, string? operationName,
            map<string|string[]>? headers)
                                                    returns GenericResponse|record {}|json|ClientError {
        http:Request request = new;
        json graphqlPayload = getGraphqlPayload(document, variables, operationName);
        request.setPayload(graphqlPayload);
        json|http:ClientError httpResponse = self.httpClient->post("", request, headers = headers);

        if httpResponse is http:ClientError {
            return handleHttpClientErrorResponse(httpResponse);
        }
        map<json>|error responseMap = httpResponse.ensureType();
        if responseMap is error {
            return error RequestError("GraphQL Client Error", responseMap);
        }
        if responseMap.hasKey("errors") {
            return handleGraphqlErrorResponse(responseMap);
        } else {
            return check performDataBinding(targetType, httpResponse);
        }
    }

    private isolated function processExecute(typedesc<GenericResponseWithErrors|record {}|json> targetType,
            string document, map<anydata>? variables, string? operationName,
            map<string|string[]>? headers)
                                            returns GenericResponseWithErrors|record {}|json|ClientError {
        http:Request request = new;
        json graphqlPayload = getGraphqlPayload(document, variables, operationName);
        request.setPayload(graphqlPayload);
        json|http:ClientError httpResponse = self.httpClient->post("", request, headers = headers);

        if httpResponse is http:ClientError {
            return handleHttpClientErrorResponse(httpResponse);
        }
        return check performDataBindingWithErrors(targetType, httpResponse);
    }

    private isolated function getWebSocketClient() returns websocket:Client|websocket:Error {
        lock {
            if self.wsClient is () {
                self.wsConfig.subProtocols = [GRAPHQL_TRANSPORT_WS];
                self.wsClient = check new (self.wsServiceUrl, self.wsConfig);
                self.wsConnectionClosed = false;
            }
            return <websocket:Client>self.wsClient;
        }
    }

    private isolated function initWsConnection() returns websocket:Error? {
        lock {
            if self.wsConnectionInit {
                return;
            }
            websocket:Client wsClient = check self.getWebSocketClient();
            ConnectionInitMessage message = {'type: WS_INIT};
            check wsClient->writeMessage(message);
            ConnectionAckMessage _ = check wsClient->readMessage();
            self.wsConnectionInit = true;
        }
    }

    private isolated function executeSubscription(string document, map<anydata>? variables, string? operationName,
            map<string|string[]>? headers, typedesc<stream<GenericResponseWithErrors|record {}|json>> targetType)
                                                returns stream<GenericResponseWithErrors|record {}|json>|ClientError {
        do {
            websocket:Client wsClient = check self.getWebSocketClient();
            check self.initWsConnection();
            string id = uuid:createType1AsString();
            Subscriber subscriber = new (id, wsClient, targetType);
            lock {
                self.subscribersMap[id] = subscriber;
            }
            json payload = getGraphqlPayload(document, variables, operationName);
            json graphqlPayload = {'type: WS_SUBSCRIBE, id, payload};
            check wsClient->writeMessage(graphqlPayload);
            _ = check start self.readFromSubscriptions(wsClient);
            return subscriber.getStream();
        } on fail error err {
            return error ClientError("Error occurred while trying to subscribe. " + err.message(), err);
        }
    }

    private isolated function readFromSubscriptions(websocket:Client wsClient) returns websocket:Error? {
        lock {
            if self.subscriptionStarted {
                return;
            }
            self.subscriptionStarted = true;
        }
        var handleMultipleSubscriptions = self.handleMultipleSubscriptions;
        var isWsConnectionClosed = self.isWsConnectionClosed;
        while true {
            lock {
                if isWsConnectionClosed() || !wsClient.isOpen() {
                    return;
                }
            }
            ClientInboundMessage message = check wsClient->readMessage();
            if message is SubscriberMessage {
                handleMultipleSubscriptions(message);
            }

            if message is PingMessage {
                PongMessage pong = {'type: WS_PONG};
                check wsClient->writeMessage(pong);
                continue;
            }
        }
    }

    private isolated function handleMultipleSubscriptions(SubscriberMessage message) {
        string id = message.id;
        lock {
            if self.subscribersMap.hasKey(id) {
                Subscriber subscriber = message is CompleteMessage ? self.subscribersMap.remove(message.id)
                    : self.subscribersMap.get(id);
                subscriber.addMessage(message.clone());
            }
        }
    }

    private isolated function isWsConnectionClosed() returns boolean {
        lock {
            return self.wsConnectionClosed;
        }
    }
}

isolated function removeHttpScheme(string serviceUrl) returns string {
    string url = serviceUrl.trim();
    if url.startsWith(HTTP) {
        return url.substring(HTTP.length());
    }
    if url.startsWith(HTTPS) {
        return url.substring(HTTPS.length());
    }
    return url;
}

isolated function getServiceUrlWithWsScheme(string serviceUrl, websocket:ClientConfiguration wsConfig) returns string {
    string url = removeHttpScheme(serviceUrl);
    if wsConfig.secureSocket is () {
        return WS.join("", url);
    }
    return WSS.join("", url);
}

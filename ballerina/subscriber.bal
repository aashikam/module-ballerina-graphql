// Copyright (c) 2023 WSO2 LLC. (http://www.wso2.com) All Rights Reserved.
//
// WSO2 LLC. licenses this file to you under the Apache License,
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

import ballerina/lang.runtime;
import ballerina/websocket;
import ballerina/jballerina.java;

public distinct isolated client class Subscriber {
    private final string id;
    private final websocket:Client wsClient;
    private final SubscriberMessage[] messages = [];
    private boolean unsubscribed = false;
    private typedesc<stream<GenericResponseWithErrors|record {}|json>> targetType;
    private typedesc<json|record{}|GenericResponseWithErrors> dataBindingType = json;

    // TODO: databinding
    isolated function init(string id, websocket:Client wsClient, typedesc<stream<GenericResponseWithErrors|record {}|json>> targetType) {
        self.id = id;
        self.wsClient = wsClient;
        self.targetType = targetType;
        self.dataBindingType = self.getDataBindingValue(targetType);
    }

    isolated function getStream() returns stream<GenericResponseWithErrors|record{}|json> {
        typedesc<GenericResponseWithErrors|record {}|json> streamType = json;
        if (streamType is typedesc<json>) {
            stream<json> newStream = new (self);
            return newStream;
        }
        stream<GenericResponseWithErrors|record{}|json> subscription = new (self);
        return subscription;
    }

    public isolated function next() returns record{|json value;|}? {
        lock {
            if self.unsubscribed || !self.wsClient.isOpen() {
                return ();
            }
            while self.messages.length() == 0 {
                runtime:sleep(1);
            }
            SubscriberMessage message = self.messages.shift();
            if message is CompleteMessage {
                self.unsubscribed = true;
                return ();
            }
            return {value: message.payload.clone()};
        }
    }

    //     public isolated function next() returns record{|json|record{}|GenericResponseWithErrors value;|}? {
    //     lock {
    //         if self.unsubscribed || !self.wsClient.isOpen() {
    //             return ();
    //         }
    //         while self.messages.length() == 0 {
    //             runtime:sleep(1);
    //         }
    //         SubscriberMessage message = self.messages.shift();
    //         if message is CompleteMessage {
    //             self.unsubscribed = true;
    //             return ();
    //         }
    //         if self.dataBindingType is typedesc<json> {
    //             return {value: message.payload.clone()};
    //         } else if self.dataBindingType is  typedesc<record{}> {
    //             json val = message.payload.clone();
    //             lock {
    //                 return {value: checkpanic val.ensureType(self.dataBindingType).clone()};
    //             }
    //         } 
    //         return {value: message.payload.clone()};
    //     }
    // }

    isolated function getDataBindingValue(typedesc<stream<GenericResponseWithErrors|record {}|json>> value) returns typedesc<json|record{}|GenericResponseWithErrors> = @java:Method {
        'class: "io.ballerina.stdlib.graphql.runtime.client.QueryExecutor",
        name: "getDataBindingValue"
    } external;

    isolated function addMessage(SubscriberMessage message) {
        lock {
            if self.unsubscribed {
                return;
            }
            self.messages.push(message.clone());
        }
    }
    
    isolated remote function unsubscribe() returns ClientError? {
        lock {
            if self.unsubscribed {
                return;
            }
            CompleteMessage message = {'type: WS_COMPLETE, id: self.id};
            websocket:Error? response = self.wsClient->writeMessage(message);
            if response is websocket:Error {
                return error ClientError(string `Error ocurred while unsubscribing. ${response.message()}`, response.cause());
            }
            self.unsubscribed = true;
        }
    }
}

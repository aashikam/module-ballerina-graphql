// Copyright (c) 2020, WSO2 Inc. (http://www.wso2.org) All Rights Reserved.
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

import ballerina/http;
import ballerina/test;

http:Listener httpListener = checkpanic new(9091);
listener Listener gqlListener = new(httpListener);

@test:Config {
    groups: ["listener", "unit"]
}
function testDocumentValidation() returns @tainted error? {
    check gqlListener.attach(serviceWithMultipleResources, "graphql_service_1");
    string document = string
    `{
    name
    id
    Voldemort
}`;
    string url = "http://localhost:9091/graphql_service_1";
    json actualPayload = check getJsonPayloadFromService(url, document);

    json expectedPayload = {
        errors:[
            {
                message: "Cannot query field \"Voldemort\" on type \"Query\".",
                locations:[
                    {
                        line:4,
                        column:5
                    }
                ]
            }
        ]
    };
    test:assertEquals(actualPayload, expectedPayload);
    check gqlListener.detach(serviceWithMultipleResources);
}

@test:Config {
    groups: ["listener", "unit"],
    dependsOn: [testDocumentValidation]
}
function testQueryResult() returns @tainted error? {
    check gqlListener.attach(serviceWithMultipleResources, "graphql_service_2");
    string document = string
    `{
    name
    id
}`;
    string url = "http://localhost:9091/graphql_service_2";
    json actualPayload = check getJsonPayloadFromService(url, document);
    json expectedPayload = {
        data: {
            name: "John Doe",
            id: 1
        }
    };
    test:assertEquals(actualPayload, expectedPayload);
    check gqlListener.detach(serviceWithMultipleResources);
}

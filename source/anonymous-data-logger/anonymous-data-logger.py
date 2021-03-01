#!/usr/bin/python
# -*- coding: utf-8 -*-
##############################################################################
#  Copyright 2020 Amazon.com, Inc. or its affiliates. All Rights Reserved.   #
#                                                                            #
#  Licensed under the Apache License Version 2.0 (the "License").            #
#  You may not use this file except in compliance with the License.          #
#  A copy of the License is located at                                       #
#                                                                            #
#      http://www.apache.org/licenses/                                       #
#                                                                            #
#  or in the "license" file accompanying this file. This file is distributed #
#  on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,        #
#  express or implied. See the License for the specific language governing   #
#  permissions and limitations under the License.                            #
##############################################################################
#
# PURPOSE:
# This function sends anonymous performance data to the AWS
# Solutions metrics API. This information is anonymous and helps improve the
# quality of the solution.
#
##############################################################################

import uuid
import lib.cfnresponse as cfn
import lib.metrics as Metrics

def handler(event, context):
    print("We got this event:\n", event)
    # Each resource returns a promise with a json object to return cloudformation.
    try:
        request = event['RequestType']
        resource = event['ResourceProperties']['Resource']
        config = event['ResourceProperties']
        # Remove ServiceToken (lambda arn) to avoid sending AccountId
        config.pop("ServiceToken", None)
        config.pop("Resource", None)
        # Add some useful fields related to stack change
        config["CFTemplate"] = (
                event["RequestType"] + "d"
        )  # Created, Updated, or Deleted
        responseData = {}
        print('Request::{} Resource:: {}'.format(request,resource))

        if request == 'Create':
            if resource == 'UUID':
                responseData = {'UUID':str(uuid.uuid4())}
                id = responseData['UUID']

            elif resource == 'AnonymousMetric':
                Metrics.send_metrics(config)
                id = 'Metrics Sent'

            else:
                print('Create failed, {} not defined in the Custom Resource'.format(resource))
                cfn.send(event, context, 'FAILED',{},context.log_stream_name)

            cfn.send(event, context, 'SUCCESS', responseData, id)

        elif request == 'Delete':

            print('RESPONSE:: {} : delete not required, sending success response'.format(resource))

            cfn.send(event, context, 'SUCCESS',{})

        else:
            print('RESPONSE:: {} Not supported'.format(request))

    except Exception as e:
        print('Exception: {}'.format(e))
        cfn.send(event, context, 'FAILED',{},context.log_stream_name)
        print (e)

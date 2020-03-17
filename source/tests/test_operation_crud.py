# Copyright 2019 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

###############################################################################
# Integration testing for the MIE workflow API
#
# PRECONDITIONS:
# MIE base stack must be deployed in your AWS account
#
# Boto3 will raise a deprecation warning (known issue). It's safe to ignore.
#
# USAGE:
#   cd tests/
#   pytest -s -W ignore::DeprecationWarning -p no:cacheprovider
#
###############################################################################

import pytest
import boto3
import json
import time
import math
import requests
import urllib3
import logging
from botocore.exceptions import ClientError
import re
import os
from jsonschema import validate

# local imports
import validation


def test_operation_api(api, api_schema, operation_configs):
    api = api()
    schema = api_schema
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    print("Running /workflow/operation API tests")
    for config in operation_configs:
        print ("\n----------------------------------------")
        print("\nTEST CONFIGURATION: {}".format(config))

        # Create the operation
        create_operation_response = api.create_operation_request(config)
        operation = create_operation_response.json()
        
        assert create_operation_response.status_code == 200
        #validation.schema(operation, api_schema["create_operation_response"])
        validation.schema(operation, api_schema["create_operation_response"])

        get_operation_response = api.get_operation_request(operation)
        operation = create_operation_response.json()
        assert get_operation_response.status_code == 200
        validation.schema(operation, api_schema["create_operation_response"])

        # Create a singleton workflow to test executing this operation
        create_workflow_response = api.create_operation_workflow_request(operation)
        workflow = create_workflow_response.json()
        assert create_workflow_response.status_code == 200
        # FIXME - need to update schema manually
        # #validation.schema(workflow, api_schema["create_workflow_response"])

        # Execute the operation and wait for it to complete
        create_workflow_execution_response = api.create_workflow_execution_request(workflow, config)
        workflow_execution = create_workflow_execution_response.json()
        assert create_workflow_execution_response.status_code == 200
        assert workflow_execution['Status'] == 'Queued'
        # FIXME - need schema
        # #validation.schema(workflow_execution, api_schema["create_workflow_execution_response"])
        workflow_execution = api.wait_for_workflow_execution(workflow_execution, 120)
        if config["Status"] == "OK":
            assert workflow_execution["Status"] == "Complete"

            # FIXME - validate the execution result
            # Check output media, metadata, operation status, workflow status, ....
        else:
            assert workflow_execution["Status"] == "Error"

        validation.operation_execution(workflow_execution, config, schema)

        # Delete the workflow
        delete_workflow_response = api.delete_operation_workflow_request(workflow)
        assert delete_workflow_response.status_code == 200
        
        #Delete the operation
        delete_operation_response = api.delete_operation_request(operation)
        assert delete_operation_response.status_code == 200




#TODO: dynamoDB remove asset
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

###############################################################################
# Integration testing for the MIE service proxy API for Amazon Transcribe
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

import urllib3
import time
import json
import pytest
import os

def test_custom_language_model(workflow_api, testing_env_variables):
    workflow_api = workflow_api()

    # List custom language models.

    list_custom_language_models_response = workflow_api.list_custom_language_models()
    assert list_custom_language_models_response.status_code == 200
    response = list_custom_language_models_response.json()
    assert "Models" in response

    # Describe a custom language model if any exist.

    if len(response["Models"] > 0):
        model_name = response["Models"][0]["ModelName"]
        body = {'model_name': model_name}
        describe_custom_language_model_response = workflow_api.describe_custom_language_model(body)
        response = describe_custom_language_model_response.json()
        assert "ModelName" in response["LanguageModel"]
        assert response["LanguageModel"]["ModelName"] == model_name

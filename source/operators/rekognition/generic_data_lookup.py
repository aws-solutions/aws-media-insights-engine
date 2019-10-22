# Copyright 2019 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

###############################################################################
# PURPOSE:
#   JSON datasets can be precomputed and uploaded along with their associated
#   media files to MIE. This lambda function is an operator that puts that
#   precomputed data into DynamoDB. Don't forget to extend the Elasticsearch
#   consumer (source/consumers/elastic/lambda_handler.py) if you want said data
#   to be added to Elasticsearch so it can be searched and rendered on the MIE
#   front-end.
#
# USAGE:
#   Users can use operator configuration parameter "Filename" to specify the
#   metadata filename. Otherwise this operator will expect to find metadata in
#   same filename as the associated media file but with a json extension. For
#   example, "Demo Video 01.mp4" must have data file "Demo Video 01.json".
#   Both the media file and the metadata file need to be in the root of the MIE
#   dataplane bucket.
#
#   To run this operator add '"GenericDataLookup":{"Enabled":true}' to the
#   workflow configuration, like this:
#
#   curl -k -X POST -H "Content-Type: application/json" --data '{"Name":"MieCompleteWorkflow","Configuration":{"defaultVideoStage":{"GenericDataLookup":{"Enabled":true}}},"Input":{"Media":{"Video":{"S3Bucket":"'$DATAPLANE_BUCKET'","S3Key":"My Video.mp4"}}}}'  $WORKFLOW_API_ENDPOINT/workflow/execution
#
#   To specify a user-defined metadata filename, use
#   '"GenericDataLookup":{"Filename":"My Video.json","Enabled":true}'
#   in the workflow configuration, like this:
#
#   curl -k -X POST -H "Content-Type: application/json" --data '{"Name":"MieCompleteWorkflow","Configuration":{"defaultVideoStage":{"GenericDataLookup":{"Filename":"My Video.json","Enabled":true}}},"Input":{"Media":{"Video":{"S3Bucket":"'$DATAPLANE_BUCKET'","S3Key":"My Video.mp4"}}}}'  $WORKFLOW_API_ENDPOINT/workflow/execution
#
###############################################################################

import json
import boto3
from MediaInsightsEngineLambdaHelper import MediaInsightsOperationHelper
from MediaInsightsEngineLambdaHelper import MasExecutionError
from MediaInsightsEngineLambdaHelper import DataPlane

# Lambda function entrypoint:
def lambda_handler(event, context):
    operator_object = MediaInsightsOperationHelper(event)
    # Get operator parameters
    try:
        workflow_id = str(event["WorkflowExecutionId"])
        asset_id = event['AssetId']
        if "Video" in operator_object.input["Media"]:
            bucket = operator_object.input["Media"]["Video"]["S3Bucket"]
            key = operator_object.input["Media"]["Video"]["S3Key"]
            file_type = key.split('.')[-1]
        elif "Audio" in operator_object.input["Media"]:
            bucket = operator_object.input["Media"]["Audio"]["S3Bucket"]
            key = operator_object.input["Media"]["Audio"]["S3Key"]
            file_type = key.split('.')[-1]
        elif "Image" in operator_object.input["Media"]:
            bucket = operator_object.input["Media"]["Image"]["S3Bucket"]
            key = operator_object.input["Media"]["Image"]["S3Key"]
            file_type = key.split('.')[-1]
        elif "Text" in operator_object.input["Media"]:
            bucket = operator_object.input["Media"]["Text"]["S3Bucket"]
            key = operator_object.input["Media"]["Text"]["S3Key"]
            file_type = key.split('.')[-1]
    except Exception:
        operator_object.update_workflow_status("Error")
        operator_object.add_workflow_metadata(GenericDataLookupError="No valid inputs")
        raise MasExecutionError(operator_object.return_output_object())

    # Get the metadata filename
    print("Looking up metadata for s3://"+bucket+"/"+key)
    # Use user-defined metadata filename if it exists
    if "Filename" in operator_object.configuration:
        metadata_filename = operator_object.configuration["Filename"]
    else:
        media_filename = key.split("/")[-1]
        metadata_filename = '.'.join(media_filename.split(".")[:-1])+".json"

    # Get metadata
    s3 = boto3.client('s3')
    try:
        print("Getting data from s3://"+bucket+"/"+metadata_filename)
        data = s3.get_object(Bucket=bucket, Key=metadata_filename)
        metadata_json = json.loads(data['Body'].read().decode('utf-8'))
    except Exception as e:
        operator_object.update_workflow_status("Error")
        operator_object.add_workflow_metadata(GenericDataLookupError="Unable read datafile. " + str(e))
        raise MasExecutionError(operator_object.return_output_object())

    # Verify that the metadata is a dict, as required by the dataplane
    if (type(metadata_json) != dict):
        operator_object.update_workflow_status("Error")
        operator_object.add_workflow_metadata(
            GenericDataLookupError="Metadata must be of type dict. Found " + str(type(metadata_json)) + " instead.")
        raise MasExecutionError(operator_object.return_output_object())

    # Save metadata to dataplane
    operator_object.add_workflow_metadata(AssetId=asset_id,WorkflowExecutionId=workflow_id)
    dataplane = DataPlane()
    metadata_upload = dataplane.store_asset_metadata(asset_id, operator_object.name, workflow_id, metadata_json)

    # Validate that the metadata was saved to the dataplane
    if "Status" not in metadata_upload:
        operator_object.add_workflow_metadata(
            GenericDataLookupError="Unable to upload metadata for asset: {asset}".format(asset=asset_id))
        operator_object.update_workflow_status("Error")
        raise MasExecutionError(operator_object.return_output_object())
    else:
        # Update the workflow status
        if metadata_upload["Status"] == "Success":
            print("Uploaded metadata for asset: {asset}".format(asset=asset_id))
            operator_object.update_workflow_status("Complete")
            return operator_object.return_output_object()
        else:
            operator_object.add_workflow_metadata(
                GenericDataLookupError="Unable to upload metadata for asset: {asset}".format(asset=asset_id))
            operator_object.update_workflow_status("Error")
            raise MasExecutionError(operator_object.return_output_object())

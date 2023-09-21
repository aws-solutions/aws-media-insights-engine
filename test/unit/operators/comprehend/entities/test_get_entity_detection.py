# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

import io, pytest
import tarfile as tar
from botocore.response import StreamingBody
from unittest.mock import MagicMock

def stub_comprehend_client(stub):
    stub.add_response(
        'list_entities_detection_jobs',
        expected_params = {
            'Filter': {
                'JobName': 'comprehend_entity_job_id'
            }
        },
        service_response = {
            'EntitiesDetectionJobPropertiesList': [{
                'JobStatus': 'COMPLETED',
                'OutputDataConfig': {
                    'S3Uri': 's3://bucket_name/comprehend/key_name'
                },
                'LanguageCode': 'en-US'
            }]
        }
    )

def stub_s3_response(stub, bucket_name: str, key_name: str, response_body: bytes):
    stub.add_response(
        'get_object',
        expected_params = {
            'Bucket': bucket_name,
            'Key': key_name
        },
        service_response = {
            'Body': StreamingBody(
                io.BytesIO(response_body),
                len(response_body)
            )
        }
    )


def make_tar_output(contents: str) -> bytes:
    """Make a gzip tarball with one output file containing the provided contents.

    The tarball will contain a single file called 'output' containing the specified string
    and it will be compressed with gzip.

    Args:
        contents (str): String to compress into the output file.

    Returns:
        The bytes of the in-memory tarball.
    """
    # Encode the string into utf-8 bytes.
    encoded_bytes = contents.encode()
    # Create a buffer that tar will write to.
    with io.BytesIO() as tarbuf:
        # Open the buffer with tar in write mode with gzip compression.
        with tar.open(mode='w:gz', fileobj=tarbuf) as targz:
            # Make a buffer with the input contents to be compressed.
            with io.BytesIO(encoded_bytes) as filebuf:
                # Create a fake TarInfo with file name "output" and size of the contents.
                tinfo = tar.TarInfo('output')
                tinfo.size = len(encoded_bytes)
                # Add the file contents to the tarball.
                targz.addfile(tinfo, filebuf)
                # Close the input file buffer.
            # Close the tarball.
        # Get the raw bytes from the output buffer before we close it. Return the bytes.
        return tarbuf.getvalue()


def test_parameter_validation():
    import comprehend.entities.get_entity_detection as lambda_function
    import MediaInsightsEngineLambdaHelper
    import helper

    operator_parameter = helper.get_operator_parameter()
    
    with pytest.raises(MediaInsightsEngineLambdaHelper.MasExecutionError) as err:
        lambda_function.lambda_handler(operator_parameter, {})
    
    operator_parameter['Status'] = 'Error'
    assert operator_parameter == err.value.args[0]

def test_comprehend_error_handling(comprehend_client_stub):
    import comprehend.entities.get_entity_detection as lambda_function
    import MediaInsightsEngineLambdaHelper
    import helper

    operator_parameter = helper.get_operator_parameter({
        'comprehend_entity_job_id': 'comprehend_entity_job_id'
    })

    comprehend_client_stub.add_client_error(
        'list_entities_detection_jobs',
        expected_params = {
            'Filter': {
                'JobName': 'comprehend_entity_job_id'
            }
        },
        service_message = 'stubbed_error_message'
    )

    with pytest.raises(MediaInsightsEngineLambdaHelper.MasExecutionError) as err:
        lambda_function.lambda_handler(operator_parameter, {})
    
    operator_parameter['Status'] = 'Error'
    assert operator_parameter == err.value.args[0]
    assert 'stubbed_error_message' in err.value.args[0]['MetaData']['comprehend_error']

def test_comprehend_job_in_progress(comprehend_client_stub):
    import comprehend.entities.get_entity_detection as lambda_function
    import MediaInsightsEngineLambdaHelper
    import helper

    # IN_PROGRESS
    operator_parameter = helper.get_operator_parameter({
        'comprehend_entity_job_id': 'comprehend_entity_job_id'
    })

    comprehend_client_stub.add_response(
        'list_entities_detection_jobs',
        expected_params = {
            'Filter': {
                'JobName': 'comprehend_entity_job_id'
            }
        },
        service_response = {
            'EntitiesDetectionJobPropertiesList': [{
                'JobStatus': 'IN_PROGRESS'
            }]
        }
    )

    response = lambda_function.lambda_handler(operator_parameter, {})
    assert response['Status'] == 'Executing'

    # SUBMITTED
    comprehend_client_stub.add_response(
        'list_entities_detection_jobs',
        expected_params = {
            'Filter': {
                'JobName': 'comprehend_entity_job_id'
            }
        },
        service_response = {
            'EntitiesDetectionJobPropertiesList': [{
                'JobStatus': 'SUBMITTED'
            }]
        }
    )

    response = lambda_function.lambda_handler(operator_parameter, {})
    assert response['Status'] == 'Executing'

    # UNKNOWN STATUS
    comprehend_client_stub.add_response(
        'list_entities_detection_jobs',
        expected_params = {
            'Filter': {
                'JobName': 'comprehend_entity_job_id'
            }
        },
        service_response = {
            'EntitiesDetectionJobPropertiesList': [{
                'JobStatus': 'UNKNOWN',
                'Message': 'test_message'
            }]
        }
    )
    with pytest.raises(MediaInsightsEngineLambdaHelper.MasExecutionError) as err:
        response = lambda_function.lambda_handler(operator_parameter, {})
    assert err.value.args[0]['Status'] == 'Error'
    assert 'comprehend returned as failed: ' in err.value.args[0]['MetaData']['comprehend_error']

def test_comprehend_job_error(comprehend_client_stub, s3_get_entity):
    import comprehend.entities.get_entity_detection as lambda_function
    import MediaInsightsEngineLambdaHelper
    import helper

    operator_parameter = helper.get_operator_parameter({
        'comprehend_entity_job_id': 'comprehend_entity_job_id'
    })

    stub_comprehend_client(comprehend_client_stub)
    stub_s3_response(
        s3_get_entity,
        'bucket_name',
        'comprehend/key_name',
        make_tar_output('hello world')
    )

    original_dataplane = lambda_function.DataPlane.store_asset_metadata
    lambda_function.DataPlane.store_asset_metadata = MagicMock(
        return_value = {
        }
    )
    with pytest.raises(MediaInsightsEngineLambdaHelper.MasExecutionError) as err:
        response = lambda_function.lambda_handler(operator_parameter, {})
        assert response['Status'] == 'Error'
        assert 'Unable to store entity data' in response['MetaData']['comprehend_error']
    assert lambda_function.DataPlane.store_asset_metadata.call_count == 1
    assert lambda_function.DataPlane.store_asset_metadata.call_args[0][0] == 'testAssetId'
    assert lambda_function.DataPlane.store_asset_metadata.call_args[0][1] == 'entities'
    assert lambda_function.DataPlane.store_asset_metadata.call_args[0][2] == 'testWorkflowId'
    assert lambda_function.DataPlane.store_asset_metadata.call_args[0][3] == {'LanguageCode': 'en-US', 'Results': ['hello world']}


    lambda_function.DataPlane.store_asset_metadata = original_dataplane

def test_comprehend_job_completed(comprehend_client_stub, s3_get_entity):
    import comprehend.entities.get_entity_detection as lambda_function
    import helper

    operator_parameter = helper.get_operator_parameter({
        'comprehend_entity_job_id': 'comprehend_entity_job_id'
    })

    stub_comprehend_client(comprehend_client_stub)
    stub_s3_response(
        s3_get_entity,
        'bucket_name',
        'comprehend/key_name',
        make_tar_output('hello world')
    )

    original_dataplane = lambda_function.DataPlane.store_asset_metadata
    lambda_function.DataPlane.store_asset_metadata = MagicMock(
        return_value = {
            'Status': 'Success'
        }
    )

    response = lambda_function.lambda_handler(operator_parameter, {})
    assert response['Status'] == 'Complete'
    assert response['MetaData']['output_uri'] == 's3://bucket_name/comprehend/key_name'
    assert lambda_function.DataPlane.store_asset_metadata.call_count == 1
    assert lambda_function.DataPlane.store_asset_metadata.call_args[0][0] == 'testAssetId'
    assert lambda_function.DataPlane.store_asset_metadata.call_args[0][1] == 'entities'
    assert lambda_function.DataPlane.store_asset_metadata.call_args[0][2] == 'testWorkflowId'
    assert lambda_function.DataPlane.store_asset_metadata.call_args[0][3] == {'LanguageCode': 'en-US', 'Results': ['hello world']}


    lambda_function.DataPlane.store_asset_metadata = original_dataplane

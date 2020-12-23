#!/bin/bash
###############################################################################
# Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# PURPOSE:
#   Build cloud formation templates for the Media Insights Engine
#
# USAGE:
#  ./build-s3-dist.sh {SOURCE-BUCKET} {VERSION} {REGION} [PROFILE]
#    SOURCE-BUCKET should be the name for the S3 bucket location where the
#      template will source the Lambda code from.
#    VERSION should be in a format like v1.0.0
#    REGION needs to be in a format like us-east-1
#    PROFILE is optional. It's the profile  that you have setup in ~/.aws/config
#      that you want to use for aws CLI commands.
#
###############################################################################

# Check to see if input has been provided:
if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
    echo "Please provide the base source bucket name,  version where the lambda code will eventually reside and the region of the deploy."
    echo "USAGE: ./build-s3-dist.sh SOURCE-BUCKET VERSION REGION [PROFILE]"
    echo "For example: ./build-s3-dist.sh mie01 v1.0.0 us-east-1 default"
    exit 1
fi

bucket=$1
version=$2
region=$3
if [ -n "$4" ]; then profile=$4; fi
s3domain="s3.$region.amazonaws.com"

# Check if region is supported:
if [ "$region" != "us-east-1" ] &&
   [ "$region" != "us-east-2" ] &&
   [ "$region" != "us-west-1" ] &&
   [ "$region" != "us-west-2" ] &&
   [ "$region" != "eu-west-1" ] &&
   [ "$region" != "eu-west-2" ] &&
   [ "$region" != "eu-central-1" ] &&
   [ "$region" != "ap-south-1" ] &&
   [ "$region" != "ap-northeast-1" ] &&
   [ "$region" != "ap-southeast-1" ] &&
   [ "$region" != "ap-southeast-2" ] &&
   [ "$region" != "ap-northeast-1" ] &&
   [ "$region" != "ap-northeast-2" ]; then
   echo "ERROR. Rekognition operations are not supported in region $region"
   exit 1
fi

# Make sure wget is installed
if ! [ -x "$(command -v wget)" ]; then
  echo "ERROR: Command not found: wget"
  echo "ERROR: wget is required for downloading lambda layers."
  echo "ERROR: Please install wget and rerun this script."
  exit 1
fi

# Build source S3 Bucket
if [[ ! -x "$(command -v aws)" ]]; then
echo "ERROR: This script requires the AWS CLI to be installed. Please install it then run again."
exit 1
fi

# Get reference for all important folders
template_dir="$PWD"
dist_dir="$template_dir/dist"
source_dir="$template_dir/../source"
echo "template_dir: ${template_dir}"

# Create and activate a temporary Python environment for this script.
echo "------------------------------------------------------------------------------"
echo "Creating a temporary Python virtualenv for this script"
echo "------------------------------------------------------------------------------"
python -c "import os; print (os.getenv('VIRTUAL_ENV'))" | grep -q None
if [ $? -ne 0 ]; then
    echo "ERROR: Do not run this script inside Virtualenv. Type \`deactivate\` and run again.";
    exit 1;
fi
command -v python3
if [ $? -ne 0 ]; then
    echo "ERROR: install Python3 before running this script"
    exit 1
fi
VENV=$(mktemp -d)
python3 -m venv "$VENV"
source "$VENV"/bin/activate
pip install --quiet boto3 chalice docopt pyyaml jsonschema aws_xray_sdk
export PYTHONPATH="$PYTHONPATH:$source_dir/lib/MediaInsightsEngineLambdaHelper/"
echo "PYTHONPATH=$PYTHONPATH"
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to install required Python libraries."
    exit 1
fi

echo "------------------------------------------------------------------------------"
echo "Create distribution directory"
echo "------------------------------------------------------------------------------"

# Setting up directories
echo "rm -rf $dist_dir"
rm -rf "$dist_dir"
# Create new dist directory
echo "mkdir -p $dist_dir"
mkdir -p "$dist_dir"

echo "------------------------------------------------------------------------------"
echo "Building MIEHelper package"
echo "------------------------------------------------------------------------------"

cd "$source_dir"/lib/MediaInsightsEngineLambdaHelper || exit 1
rm -rf build
rm -rf dist
rm -rf Media_Insights_Engine_Lambda_Helper.egg-info
python3 setup.py bdist_wheel > /dev/null
echo -n "Created: "
find "$source_dir"/lib/MediaInsightsEngineLambdaHelper/dist/
cd "$template_dir"/ || exit 1

echo "------------------------------------------------------------------------------"
echo "Downloading Lambda Layers"
echo "------------------------------------------------------------------------------"

echo "Downloading https://rodeolabz-$region.$s3domain/media_insights_engine/media_insights_engine_lambda_layer_python3.6.zip"
wget -q https://rodeolabz-"$region"."$s3domain"/media_insights_engine/media_insights_engine_lambda_layer_python3.6.zip
echo "Downloading https://rodeolabz-$region.$s3domain/media_insights_engine/media_insights_engine_lambda_layer_python3.7.zip"
wget -q https://rodeolabz-"$region"."$s3domain"/media_insights_engine/media_insights_engine_lambda_layer_python3.7.zip
echo "Downloading https://rodeolabz-$region.$s3domain/media_insights_engine/media_insights_engine_lambda_layer_python3.8.zip"
wget -q https://rodeolabz-"$region"."$s3domain"/media_insights_engine/media_insights_engine_lambda_layer_python3.8.zip

echo "Copying Lambda layer zips to $dist_dir:"

cp -v media_insights_engine_lambda_layer_python3.6.zip "$dist_dir"
cp -v media_insights_engine_lambda_layer_python3.7.zip "$dist_dir"
cp -v media_insights_engine_lambda_layer_python3.8.zip "$dist_dir"

cd "$template_dir" || exit 1

echo "------------------------------------------------------------------------------"
echo "CloudFormation Templates"
echo "------------------------------------------------------------------------------"

echo "Preparing template files:"
cp "$source_dir/operators/operator-library.yaml" "$dist_dir/media-insights-operator-library.template"
cp "$template_dir/media-insights-stack.yaml" "$dist_dir/media-insights-stack.template"
cp "$template_dir/string.yaml" "$dist_dir/string.template"
cp "$template_dir/media-insights-test-operations-stack.yaml" "$dist_dir/media-insights-test-operations-stack.template"
cp "$template_dir/media-insights-dataplane-streaming-stack.template" "$dist_dir/media-insights-dataplane-streaming-stack.template"
find "$dist_dir"
echo "Updating code source bucket in template files with '$bucket'"
echo "Updating solution version in template files with '$version'"
new_bucket="s/%%BUCKET_NAME%%/$bucket/g"
new_version="s/%%VERSION%%/$version/g"
# Update templates in place. Copy originals to [filename].orig
sed -i.orig -e "$new_bucket" "$dist_dir/media-insights-stack.template"
sed -i.orig -e "$new_version" "$dist_dir/media-insights-stack.template"
sed -i.orig -e "$new_bucket" "$dist_dir/media-insights-operator-library.template"
sed -i.orig -e "$new_version" "$dist_dir/media-insights-operator-library.template"
sed -i.orig -e "$new_bucket" "$dist_dir/media-insights-test-operations-stack.template"
sed -i.orig -e "$new_version" "$dist_dir/media-insights-test-operations-stack.template"
sed -i.orig -e "$new_bucket" "$dist_dir/media-insights-dataplane-streaming-stack.template"
sed -i.orig -e "$new_version" "$dist_dir/media-insights-dataplane-streaming-stack.template"

echo "------------------------------------------------------------------------------"
echo "Operators"
echo "------------------------------------------------------------------------------"

# ------------------------------------------------------------------------------"
# Operator Failed Lambda
# ------------------------------------------------------------------------------"

echo "Building 'operator failed' function"
cd "$source_dir/operators/operator_failed" || exit 1
[ -e dist ] && rm -rf dist
mkdir -p dist
zip -q dist/operator_failed.zip operator_failed.py
cp "./dist/operator_failed.zip" "$dist_dir/operator_failed.zip"
rm -rf ./dist

# ------------------------------------------------------------------------------"
# Mediainfo Operation
# ------------------------------------------------------------------------------"

echo "Building Mediainfo function"
cd "$source_dir/operators/mediainfo" || exit 1
# Make lambda package
[ -e dist ] && rm -rf dist
mkdir -p dist
# Add the app code to the dist zip.
zip -q dist/mediainfo.zip mediainfo.py
# Zip is ready. Copy it to the distribution directory.
cp "./dist/mediainfo.zip" "$dist_dir/mediainfo.zip"
rm -rf ./dist

# ------------------------------------------------------------------------------"
# Mediaconvert Operations
# ------------------------------------------------------------------------------"

echo "Building Media Convert function"
cd "$source_dir/operators/mediaconvert" || exit 1
[ -e dist ] && rm -rf dist
mkdir -p dist
zip -q dist/start_media_convert.zip start_media_convert.py
zip -q dist/get_media_convert.zip get_media_convert.py
cp "./dist/start_media_convert.zip" "$dist_dir/start_media_convert.zip"
cp "./dist/get_media_convert.zip" "$dist_dir/get_media_convert.zip"
rm -rf ./dist

# ------------------------------------------------------------------------------"
# Thumbnail Operations
# ------------------------------------------------------------------------------"

echo "Building Thumbnail function"
cd "$source_dir/operators/thumbnail" || exit 1
# Make lambda package
[ -e dist ] && rm -rf dist
mkdir -p dist
if ! [ -d ./dist/start_thumbnail.zip ]; then
  zip -q -r9 ./dist/start_thumbnail.zip .
elif [ -d ./dist/start_thumbnail.zip ]; then
  echo "Package already present"
fi
zip -q -g dist/start_thumbnail.zip start_thumbnail.py
cp "./dist/start_thumbnail.zip" "$dist_dir/start_thumbnail.zip"

if ! [ -d ./dist/check_thumbnail.zip ]; then
  zip -q -r9 ./dist/check_thumbnail.zip .
elif [ -d ./dist/check_thumbnail.zip ]; then
  echo "Package already present"
fi
zip -q -g dist/check_thumbnail.zip check_thumbnail.py
cp "./dist/check_thumbnail.zip" "$dist_dir/check_thumbnail.zip"
rm -rf ./dist

# ------------------------------------------------------------------------------"
# Transcribe Operations
# ------------------------------------------------------------------------------"

echo "Building Transcribe functions"
cd "$source_dir/operators/transcribe" || exit 1
[ -e dist ] && rm -rf dist
mkdir -p dist
zip -q -g ./dist/start_transcribe.zip ./start_transcribe.py
zip -q -g ./dist/get_transcribe.zip ./get_transcribe.py
cp "./dist/start_transcribe.zip" "$dist_dir/start_transcribe.zip"
cp "./dist/get_transcribe.zip" "$dist_dir/get_transcribe.zip"
rm -rf ./dist

# ------------------------------------------------------------------------------"
# Create Captions Operations
# ------------------------------------------------------------------------------"

echo "Building Webcaptions function"
cd "$source_dir/operators/captions" || exit
[ -e dist ] && rm -rf dist
mkdir -p dist

[ -e package ] && rm -r package
mkdir -p package
echo "preparing packages from requirements.txt"
# Package dependencies listed in requirements.txt
pushd package || exit 1
# Handle distutils install errors with setup.cfg
touch ./setup.cfg
echo "[install]" > ./setup.cfg
echo "prefix= " >> ./setup.cfg
# Try and handle failure if pip version mismatch
if [ -x "$(command -v pip)" ]; then
  pip install --quiet -r ../requirements.txt --target .
elif [ -x "$(command -v pip3)" ]; then
  echo "pip not found, trying with pip3"
  pip3 install --quiet -r ../requirements.txt --target .
elif ! [ -x "$(command -v pip)" ] && ! [ -x "$(command -v pip3)" ]; then
  echo "No version of pip installed. This script requires pip. Cleaning up and exiting."
  exit 1
fi
zip -q -r9 ../dist/webcaptions.zip .
popd || exit 1

zip -g ./dist/webcaptions.zip ./webcaptions.py
cp "./dist/webcaptions.zip" "$dist_dir/webcaptions.zip"

# ------------------------------------------------------------------------------"
# Translate Operations
# ------------------------------------------------------------------------------"

echo "Building Translate function"
cd "$source_dir/operators/translate" || exit 1
[ -e dist ] && rm -rf dist
mkdir -p dist
[ -e package ] && rm -rf package
mkdir -p package
echo "create requirements for lambda"
# Make lambda package
pushd package || exit 1
echo "create lambda package"
# Handle distutils install errors
touch ./setup.cfg
echo "[install]" > ./setup.cfg
echo "prefix= " >> ./setup.cfg
# Try and handle failure if pip version mismatch
if [ -x "$(command -v pip)" ]; then
  pip install --quiet -r ../requirements.txt --target .
elif [ -x "$(command -v pip3)" ]; then
  echo "pip not found, trying with pip3"
  pip3 install --quiet -r ../requirements.txt --target .
elif ! [ -x "$(command -v pip)" ] && ! [ -x "$(command -v pip3)" ]; then
 echo "No version of pip installed. This script requires pip. Cleaning up and exiting."
 exit 1
fi
if ! [ -d ../dist/start_translate.zip ]; then
  zip -q -r9 ../dist/start_translate.zip .

elif [ -d ../dist/start_translate.zip ]; then
  echo "Package already present"
fi
popd || exit 1
zip -q -g ./dist/start_translate.zip ./start_translate.py
cp "./dist/start_translate.zip" "$dist_dir/start_translate.zip"
rm -rf ./dist ./package

# ------------------------------------------------------------------------------"
# Polly operators
# ------------------------------------------------------------------------------"

echo "Building Polly function"
cd "$source_dir/operators/polly" || exit 1
[ -e dist ] && rm -rf dist
mkdir -p dist
zip -q -g ./dist/start_polly.zip ./start_polly.py
zip -q -g ./dist/get_polly.zip ./get_polly.py
cp "./dist/start_polly.zip" "$dist_dir/start_polly.zip"
cp "./dist/get_polly.zip" "$dist_dir/get_polly.zip"
rm -rf ./dist

# ------------------------------------------------------------------------------"
# Comprehend operators
# ------------------------------------------------------------------------------"

echo "Building Comprehend function"
cd "$source_dir/operators/comprehend" || exit 1

[ -e dist ] && rm -rf dist
[ -e package ] && rm -rf package
for dir in ./*;
  do
    echo "$dir"
    cd "$dir" || exit 1
    mkdir -p dist
    mkdir -p package
    echo "creating requirements for lambda"
    # Package dependencies listed in requirements.txt
    pushd package || exit 1
    # Handle distutils install errors with setup.cfg
    touch ./setup.cfg
    echo "[install]" > ./setup.cfg
    echo "prefix= " >> ./setup.cfg
    if [[ $dir == "./key_phrases" ]]; then
      if ! [ -d ../dist/start_key_phrases.zip ]; then
        zip -q -r9 ../dist/start_key_phrases.zip .
      elif [ -d ../dist/start_key_phrases.zip ]; then
        echo "Package already present"
      fi
      if ! [ -d ../dist/get_key_phrases.zip ]; then
        zip -q -r9 ../dist/get_key_phrases.zip .

      elif [ -d ../dist/get_key_phrases.zip ]; then
        echo "Package already present"
      fi
      popd || exit 1
      zip -q -g dist/start_key_phrases.zip start_key_phrases.py
      zip -q -g dist/get_key_phrases.zip get_key_phrases.py
      echo "$PWD"
      cp ./dist/start_key_phrases.zip "$dist_dir/start_key_phrases.zip"
      cp ./dist/get_key_phrases.zip "$dist_dir/get_key_phrases.zip"
      mv -f ./dist/*.zip "$dist_dir"
    elif [[ "$dir" == "./entities" ]]; then
      if ! [ -d ../dist/start_entity_detection.zip ]; then
      zip -q -r9 ../dist/start_entity_detection.zip .
      elif [ -d ../dist/start_entity_detection.zip ]; then
      echo "Package already present"
      fi
      if ! [ -d ../dist/get_entity_detection.zip ]; then
      zip -q -r9 ../dist/get_entity_detection.zip .
      elif [ -d ../dist/get_entity_detection.zip ]; then
      echo "Package already present"
      fi
      popd || exit 1
      echo "$PWD"
      zip -q -g dist/start_entity_detection.zip start_entity_detection.py
      zip -q -g dist/get_entity_detection.zip get_entity_detection.py
      mv -f ./dist/*.zip "$dist_dir"
    fi
    rm -rf ./dist ./package
    cd ..
  done;

# ------------------------------------------------------------------------------"
# Rekognition operators
# ------------------------------------------------------------------------------"

echo "Building Rekognition functions"
cd "$source_dir/operators/rekognition" || exit 1
# Make lambda package
echo "creating lambda packages"
# All the Python dependencies for Rekognition functions are in the Lambda layer, so
# we can deploy the zipped source file without dependencies.
zip -q -r9 generic_data_lookup.zip generic_data_lookup.py
zip -q -r9 start_celebrity_recognition.zip start_celebrity_recognition.py
zip -q -r9 check_celebrity_recognition_status.zip check_celebrity_recognition_status.py
zip -q -r9 start_content_moderation.zip start_content_moderation.py
zip -q -r9 check_content_moderation_status.zip check_content_moderation_status.py
zip -q -r9 start_face_detection.zip start_face_detection.py
zip -q -r9 check_face_detection_status.zip check_face_detection_status.py
zip -q -r9 start_face_search.zip start_face_search.py
zip -q -r9 check_face_search_status.zip check_face_search_status.py
zip -q -r9 start_label_detection.zip start_label_detection.py
zip -q -r9 check_label_detection_status.zip check_label_detection_status.py
zip -q -r9 start_person_tracking.zip start_person_tracking.py
zip -q -r9 check_person_tracking_status.zip check_person_tracking_status.py
zip -q -r9 start_text_detection.zip start_text_detection.py
zip -q -r9 check_text_detection_status.zip check_text_detection_status.py


# remove this when service is GA

[ -e dist ] && rm -rf dist
mkdir -p dist
cd dist
cp ../start_technical_cue_detection.py .
mkdir rekognition-segment-detection
cd rekognition-segment-detection
mkdir 2016-06-27
cd 2016-06-27
cp ../../../service-2.json .
cd ../../
zip -q -r9 ../start_technical_cue_detection.zip *
cd ../


[ -e dist ] && rm -rf dist
mkdir -p dist
cd dist
cp ../check_technical_cue_status.py .
mkdir rekognition-segment-detection
cd rekognition-segment-detection
mkdir 2016-06-27
cd 2016-06-27
cp ../../../service-2.json .
cd ../../
zip -q -r9 ../check_technical_cue_status.zip *
cd ../

mv -f ./*.zip "$dist_dir"


[ -e dist ] && rm -rf dist
mkdir -p dist
cd dist
cp ../start_shot_detection.py .
mkdir rekognition-segment-detection
cd rekognition-segment-detection
mkdir 2016-06-27
cd 2016-06-27
cp ../../../service-2.json .
cd ../../
zip -q -r9 ../start_shot_detection.zip *
cd ../

[ -e dist ] && rm -rf dist
mkdir -p dist
cd dist
cp ../check_shot_detection_status.py .
mkdir rekognition-segment-detection
cd rekognition-segment-detection
mkdir 2016-06-27
cd 2016-06-27
cp ../../../service-2.json .
cd ../../
zip -q -r9 ../check_shot_detection_status.zip *
cd ../

mv -f ./*.zip "$dist_dir"


# ------------------------------------------------------------------------------"
# Test operators
# ------------------------------------------------------------------------------"

echo "Building test operators"
cd "$source_dir/operators/test" || exit
[ -e dist ] && rm -rf dist
mkdir -p dist
zip -q -g ./dist/test_operations.zip ./test.py
cp "./dist/test_operations.zip" "$dist_dir/test_operations.zip"
rm -rf ./dist

echo "------------------------------------------------------------------------------"
echo "DynamoDB Stream Function"
echo "------------------------------------------------------------------------------"

echo "Building DDB Stream function"
cd "$source_dir/dataplanestream" || exit 1
[ -e dist ] && rm -rf dist
mkdir -p dist
[ -e package ] && rm -rf package
mkdir -p package
echo "preparing packages from requirements.txt"
# Package dependencies listed in requirements.txt
pushd package || exit 1
# Handle distutils install errors with setup.cfg
touch ./setup.cfg
echo "[install]" > ./setup.cfg
echo "prefix= " >> ./setup.cfg
# Try and handle failure if pip version mismatch
if [ -x "$(command -v pip)" ]; then
  pip install --quiet -r ../requirements.txt --target .
elif [ -x "$(command -v pip3)" ]; then
  echo "pip not found, trying with pip3"
  pip3 install --quiet -r ../requirements.txt --target .
elif ! [ -x "$(command -v pip)" ] && ! [ -x "$(command -v pip3)" ]; then
  echo "No version of pip installed. This script requires pip. Cleaning up and exiting."
  exit 1
fi
zip -q -r9 ../dist/ddbstream.zip .
popd || exit 1

zip -q -g dist/ddbstream.zip ./*.py
cp "./dist/ddbstream.zip" "$dist_dir/ddbstream.zip"
rm -rf ./dist ./package


echo "------------------------------------------------------------------------------"
echo "Workflow Scheduler"
echo "------------------------------------------------------------------------------"

echo "Building Workflow scheduler"
cd "$source_dir/workflow" || exit 1
[ -e dist ] && rm -rf dist
mkdir -p dist
[ -e package ] && rm -rf package
mkdir -p package
echo "preparing packages from requirements.txt"
# Package dependencies listed in requirements.txt
cd package || exit 1
# Handle distutils install errors with setup.cfg
touch ./setup.cfg
echo "[install]" > ./setup.cfg
echo "prefix= " >> ./setup.cfg
cd ..
# Try and handle failure if pip version mismatch
if [ -x "$(command -v pip)" ]; then
  pip install --quiet -r ./requirements.txt --target package/
elif [ -x "$(command -v pip3)" ]; then
  echo "pip not found, trying with pip3"
  pip3 install --quiet -r ./requirements.txt --target package/
elif ! [ -x "$(command -v pip)" ] && ! [ -x "$(command -v pip3)" ]; then
  echo "No version of pip installed. This script requires pip. Cleaning up and exiting."
  exit 1
fi
cd package || exit 1
zip -q -r9 ../dist/workflow.zip .
cd ..
zip -q -g dist/workflow.zip ./*.py
cp "./dist/workflow.zip" "$dist_dir/workflow.zip"
rm -rf ./dist ./package/

echo "------------------------------------------------------------------------------"
echo "Workflow API Stack"
echo "------------------------------------------------------------------------------"

echo "Building Workflow Lambda function"
cd "$source_dir/workflowapi" || exit 1
[ -e dist ] && rm -rf dist
mkdir -p dist
if ! [ -x "$(command -v chalice)" ]; then
  echo 'Chalice is not installed. It is required for this solution. Exiting.'
  exit 1
fi

# Remove chalice deployments to force redeploy when there are changes to configuration only
# Otherwise, chalice will use the existing deployment package 
[ -e .chalice/deployments ] && rm -rf .chalice/deployments

echo "running chalice..."
chalice package --merge-template external_resources.json dist
echo "...chalice done"
echo "cp ./dist/sam.json $dist_dir/media-insights-workflowapi-stack.template"
cp dist/sam.json "$dist_dir"/media-insights-workflowapi-stack.template
if [ $? -ne 0 ]; then
  echo "ERROR: Failed to build workflow api template"
  exit 1
fi
echo "cp ./dist/deployment.zip $dist_dir/workflowapi.zip"
cp ./dist/deployment.zip "$dist_dir"/workflowapi.zip
if [ $? -ne 0 ]; then
  echo "ERROR: Failed to build workflow api template"
  exit 1
fi
rm -rf ./dist

echo "------------------------------------------------------------------------------"
echo "Workflow Execution DynamoDB Stream Function"
echo "------------------------------------------------------------------------------"

echo "Building Workflow Execution DDB Stream function"
cd "$source_dir/workflowstream" || exit 1
[ -e dist ] && rm -r dist
mkdir -p dist
[ -e package ] && rm -r package
mkdir -p package
echo "preparing packages from requirements.txt"
# Package dependencies listed in requirements.txt
pushd package || exit 1
# Handle distutils install errors with setup.cfg
touch ./setup.cfg
echo "[install]" > ./setup.cfg
echo "prefix= " >> ./setup.cfg
# Try and handle failure if pip version mismatch
if [ -x "$(command -v pip)" ]; then
  pip install --quiet -r ../requirements.txt --target .
elif [ -x "$(command -v pip3)" ]; then
  echo "pip not found, trying with pip3"
  pip3 install --quiet -r ../requirements.txt --target .
elif ! [ -x "$(command -v pip)" ] && ! [ -x "$(command -v pip3)" ]; then
  echo "No version of pip installed. This script requires pip. Cleaning up and exiting."
  exit 1
fi
zip -q -r9 ../dist/workflowstream.zip .
popd || exit 1

zip -q -g dist/workflowstream.zip ./*.py
cp "./dist/workflowstream.zip" "$dist_dir/workflowstream.zip"

echo "------------------------------------------------------------------------------"
echo "Dataplane API Stack"
echo "------------------------------------------------------------------------------"

echo "Building Dataplane Stack"
cd "$source_dir/dataplaneapi" || exit 1
[ -e dist ] && rm -rf dist
mkdir -p dist
if ! [ -x "$(command -v chalice)" ]; then
  echo 'Chalice is not installed. It is required for this solution. Exiting.'
  exit 1
fi

# Remove chalice deployments to force redeploy when there are changes to configuration only
# Otherwise, chalice will use the existing deployment package 
[ -e .chalice/deployments ] && rm -rf .chalice/deployments

chalice package --merge-template external_resources.json dist
echo "cp ./dist/sam.json $dist_dir/media-insights-dataplane-api-stack.template"
cp dist/sam.json "$dist_dir"/media-insights-dataplane-api-stack.template
if [ $? -ne 0 ]; then
  echo "ERROR: Failed to build dataplane api template"
  exit 1
fi
echo "cp ./dist/deployment.zip $dist_dir/dataplaneapi.zip"
cp ./dist/deployment.zip "$dist_dir"/dataplaneapi.zip
if [ $? -ne 0 ]; then
  echo "ERROR: Failed to build dataplane api template"
  exit 1
fi
rm -rf ./dist


echo "------------------------------------------------------------------------------"
echo "Copy dist to S3"
echo "------------------------------------------------------------------------------"

echo "Copying the prepared distribution to S3..."
for file in "$dist_dir"/*.zip
do
  if [ -n "$profile" ]; then
    aws s3 cp "$file" s3://"$bucket"/media_insights_engine/"$version"/code/ --profile "$profile"
  else
    aws s3 cp "$file" s3://"$bucket"/media_insights_engine/"$version"/code/
  fi
done
for file in "$dist_dir"/*.template
do
  if [ -n "$profile" ]; then
    aws s3 cp "$file" s3://"$bucket"/media_insights_engine/"$version"/cf/ --profile "$profile"
  else
    aws s3 cp "$file" s3://"$bucket"/media_insights_engine/"$version"/cf/
  fi
done

echo "------------------------------------------------------------------------------"
echo "S3 packaging complete"
echo "------------------------------------------------------------------------------"

# Deactivate and remove the temporary python virtualenv used to run this script
deactivate
rm -rf "$VENV"

echo "------------------------------------------------------------------------------"
echo "Cleaning up complete"
echo "------------------------------------------------------------------------------"

echo ""
echo "Template to deploy:"
echo "TEMPLATE='"https://"$bucket"."$s3domain"/media_insights_engine/"$version"/cf/media-insights-stack.template"'"

touch $dist_dir/templateUrl.txt
echo "https://"$bucket"."$s3domain"/media_insights_engine/"$version"/cf/media-insights-stack.template" > ${dist_dir}/templateUrl.txt

echo "------------------------------------------------------------------------------"
echo "Done"
echo "------------------------------------------------------------------------------"

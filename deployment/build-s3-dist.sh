#!/bin/bash
###############################################################################
# Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# PURPOSE:
#   Build cloud formation templates for the Media Insights Engine
#
# USAGE:
#  ./build-s3-dist.sh [-h] [-v] [--no-layer] --template-bucket {TEMPLATE_BUCKET} --code-bucket {CODE_BUCKET} --version {VERSION} --region {REGION}
#    TEMPLATE_BUCKET should be the name for the S3 bucket location where MIE
#      cloud formation templates should be saved.
#    CODE_BUCKET should be the name for the S3 bucket location where cloud
#      formation templates should find Lambda source code packages.
#    VERSION should be in a format like v1.0.0
#    REGION needs to be in a format like us-east-1
#
#    The following options are available:
#
#     -h | --help       Print usage
#     -v | --verbose    Print script debug info
#     --no-layer        Do not build AWS Lamda layer
#
###############################################################################

trap cleanup SIGINT SIGTERM ERR EXIT

usage() {
  msg "$msg"
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [--no-layer] --template-bucket TEMPLATE_BUCKET --code-bucket CODE_BUCKET --version VERSION --region REGION

Script description here.

Available options:

-h, --help        Print this help and exit (optional)
-v, --verbose     Print script debug info (optional)
--no-layer        Do not build AWS Lamda layer (optional)
--template-bucket S3 bucket to put cloud formation templates
--code-bucket     S3 bucket to put Lambda code packages
--version         Arbitrary string indicating build version
--region          AWS Region, formatted like us-west-2
EOF
  exit 1
}

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  # Deactivate and remove the temporary python virtualenv used to run this script
  if [[ "$VIRTUAL_ENV" != "" ]];
  then
    deactivate
    rm -rf "$VENV"
    echo "------------------------------------------------------------------------------"
    echo "Cleaning up complete"
    echo "------------------------------------------------------------------------------"
  fi
}

msg() {
  echo >&2 -e "${1-}"
}

die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  msg "$msg"
  exit "$code"
}

parse_params() {
  # default values of variables set from params
  flag=0
  param=''

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    --no-layer) NO_LAYER=1 ;;
    --template-bucket)
      global_bucket="${2}"
      shift
      ;;
    --code-bucket)
      regional_bucket="${2}"
      shift
      ;;
    --version)
      version="${2}"
      shift
      ;;
    --region)
      region="${2}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  # check required params and arguments
  [[ -z "${global_bucket}" ]] && usage "Missing required parameter: template-bucket"
  [[ -z "${regional_bucket}" ]] && usage "Missing required parameter: code-bucket"
  [[ -z "${version}" ]] && usage "Missing required parameter: version"
  [[ -z "${region}" ]] && usage "Missing required parameter: region"

  return 0
}

parse_params "$@"
msg "Build parameters:"
msg "- TEMPLATE_BUCKET: ${global_bucket}"
msg "- CODE_BUCKET: ${regional_bucket}"
msg "- VERSION: ${version}"
msg "- REGION: ${region}"

echo ""
sleep 3
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
template_dist_dir="$template_dir/global-s3-assets"
build_dist_dir="$template_dir/regional-s3-assets"
dist_dir="$template_dir/dist"
source_dir="$template_dir/../source"

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
echo "rm -rf $template_dist_dir"
rm -rf "$template_dist_dir"
echo "mkdir -p $template_dist_dir"
mkdir -p "$template_dist_dir"
echo "mkdir -p $template_dist_dir/website"
mkdir -p "$template_dist_dir"/website
echo "rm -rf $build_dist_dir"
rm -rf "$build_dist_dir"
echo "mkdir -p $build_dist_dir"
mkdir -p "$build_dist_dir"

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
echo "Building Lambda Layers"
echo "------------------------------------------------------------------------------"
# Build MediaInsightsEngineLambdaHelper Python package
cd "$template_dir"/lambda_layer_factory/ || exit 1
rm -f media_insights_engine_lambda_layer_python*.zip*
rm -f Media_Insights_Engine*.whl
cp -R "$source_dir"/lib/MediaInsightsEngineLambdaHelper .
cd MediaInsightsEngineLambdaHelper/ || exit 1
echo "Building MIE Lambda Helper python library"
python3 setup.py bdist_wheel > /dev/null
cp dist/*.whl ../
cp dist/*.whl "$source_dir"/lib/MediaInsightsEngineLambdaHelper/dist/
echo "MIE Lambda Helper python library is at $source_dir/lib/MediaInsightsEngineLambdaHelper/dist/"
cd "$source_dir"/lib/MediaInsightsEngineLambdaHelper/dist/ || exit 1
ls -1 "$(pwd)"/*.whl
if [ $? -ne 0 ]; then
  echo "ERROR: Failed to build MIE Lambda Helper python library"
  exit 1
fi
cd "$template_dir"/lambda_layer_factory/ || exit 1
rm -rf MediaInsightsEngineLambdaHelper/
file=$(ls Media_Insights_Engine*.whl)
# Note, $(pwd) will be mapped to /packages/ in the Docker container used for building the Lambda zip files. We reference /packages/ in requirements.txt for that reason.
# Add the whl file to requirements.txt if it is not already there
mv requirements.txt requirements.txt.old
cat requirements.txt.old | grep -v "Media_Insights_Engine_Lambda_Helper" > requirements.txt
echo "/packages/$file" >> requirements.txt;
# Build Lambda layer zip files and rename them to the filenames expected by media-insights-stack.yaml. The Lambda layer build script runs in Docker.
# If Docker is not installed, then we'll use prebuilt Lambda layer zip files.
echo "Running build-lambda-layer.sh:"
echo ""
rm -rf lambda_layer-python-* lambda_layer-python*.zip
./build-lambda-layer.sh requirements.txt > /dev/null
if [ $? -eq 0 ]; then
  mv lambda_layer-python3.6.zip media_insights_engine_lambda_layer_python3.6.zip
  mv lambda_layer-python3.7.zip media_insights_engine_lambda_layer_python3.7.zip
  mv lambda_layer-python3.8.zip media_insights_engine_lambda_layer_python3.8.zip
  rm -rf lambda_layer-python-3.6/ lambda_layer-python-3.7/ lambda_layer-python-3.8/
  echo "Lambda layer build script completed.";
else
  echo "WARNING: Lambda layer build script failed. We'll use a pre-built Lambda layers instead.";
  echo "Downloading https://rodeolabz-$region.$s3domain/media_insights_engine/media_insights_engine_lambda_layer_python3.6.zip"
  wget -q https://rodeolabz-"$region"."$s3domain"/media_insights_engine/media_insights_engine_lambda_layer_python3.6.zip
  echo "Downloading https://rodeolabz-$region.$s3domain/media_insights_engine/media_insights_engine_lambda_layer_python3.7.zip"
  wget -q https://rodeolabz-"$region"."$s3domain"/media_insights_engine/media_insights_engine_lambda_layer_python3.7.zip
  echo "Downloading https://rodeolabz-$region.$s3domain/media_insights_engine/media_insights_engine_lambda_layer_python3.8.zip"
  wget -q https://rodeolabz-"$region"."$s3domain"/media_insights_engine/media_insights_engine_lambda_layer_python3.8.zip
fi
echo "Copying Lambda layer zips to $build_dist_dir:"
cp -v media_insights_engine_lambda_layer_python3.6.zip "$build_dist_dir"
cp -v media_insights_engine_lambda_layer_python3.7.zip "$build_dist_dir"
cp -v media_insights_engine_lambda_layer_python3.8.zip "$build_dist_dir"
mv requirements.txt.old requirements.txt
cd "$template_dir" || exit 1

echo "------------------------------------------------------------------------------"
echo "CloudFormation Templates"
echo "------------------------------------------------------------------------------"

echo "Preparing template files:"
cp "$source_dir/operators/operator-library.yaml" "$template_dist_dir/media-insights-operator-library.template"
cp "$template_dir/media-insights-stack.yaml" "$template_dist_dir/media-insights-stack.template"
cp "$template_dir/string.yaml" "$template_dist_dir/string.template"
cp "$template_dir/media-insights-test-operations-stack.yaml" "$template_dist_dir/media-insights-test-operations-stack.template"
cp "$template_dir/media-insights-dataplane-streaming-stack.template" "$template_dist_dir/media-insights-dataplane-streaming-stack.template"
find "$template_dist_dir"
echo "Updating template source bucket in template files with '$global_bucket'"
echo "Updating code source bucket in template files with '$regional_bucket'"
echo "Updating solution version in template files with '$version'"
new_global_bucket="s/%%GLOBAL_BUCKET_NAME%%/$global_bucket/g"
new_regional_bucket="s/%%REGIONAL_BUCKET_NAME%%/$regional_bucket/g"
new_version="s/%%VERSION%%/$version/g"
# Update templates in place. Copy originals to [filename].orig
sed -i.orig -e "$new_global_bucket" "$template_dist_dir/media-insights-stack.template"
sed -i.orig -e "$new_regional_bucket" "$template_dist_dir/media-insights-stack.template"
sed -i.orig -e "$new_version" "$template_dist_dir/media-insights-stack.template"
sed -i.orig -e "$new_global_bucket" "$template_dist_dir/media-insights-operator-library.template"
sed -i.orig -e "$new_regional_bucket" "$template_dist_dir/media-insights-operator-library.template"
sed -i.orig -e "$new_version" "$template_dist_dir/media-insights-operator-library.template"
sed -i.orig -e "$new_global_bucket" "$template_dist_dir/media-insights-test-operations-stack.template"
sed -i.orig -e "$new_regional_bucket" "$template_dist_dir/media-insights-test-operations-stack.template"
sed -i.orig -e "$new_version" "$template_dist_dir/media-insights-test-operations-stack.template"
sed -i.orig -e "$new_global_bucket" "$template_dist_dir/media-insights-dataplane-streaming-stack.template"
sed -i.orig -e "$new_regional_bucket" "$template_dist_dir/media-insights-dataplane-streaming-stack.template"
sed -i.orig -e "$new_version" "$template_dist_dir/media-insights-dataplane-streaming-stack.template"

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
cp "./dist/operator_failed.zip" "$build_dist_dir/operator_failed.zip"
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
cp "./dist/mediainfo.zip" "$build_dist_dir/mediainfo.zip"
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
cp "./dist/start_media_convert.zip" "$build_dist_dir/start_media_convert.zip"
cp "./dist/get_media_convert.zip" "$build_dist_dir/get_media_convert.zip"
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
cp "./dist/start_thumbnail.zip" "$build_dist_dir/start_thumbnail.zip"

if ! [ -d ./dist/check_thumbnail.zip ]; then
  zip -q -r9 ./dist/check_thumbnail.zip .
elif [ -d ./dist/check_thumbnail.zip ]; then
  echo "Package already present"
fi
zip -q -g dist/check_thumbnail.zip check_thumbnail.py
cp "./dist/check_thumbnail.zip" "$build_dist_dir/check_thumbnail.zip"
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
cp "./dist/start_transcribe.zip" "$build_dist_dir/start_transcribe.zip"
cp "./dist/get_transcribe.zip" "$build_dist_dir/get_transcribe.zip"
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
cp "./dist/webcaptions.zip" "$build_dist_dir/webcaptions.zip"

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
cp "./dist/start_translate.zip" "$build_dist_dir/start_translate.zip"
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
cp "./dist/start_polly.zip" "$build_dist_dir/start_polly.zip"
cp "./dist/get_polly.zip" "$build_dist_dir/get_polly.zip"
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
      cp ./dist/start_key_phrases.zip "$build_dist_dir/start_key_phrases.zip"
      cp ./dist/get_key_phrases.zip "$build_dist_dir/get_key_phrases.zip"
      mv -f ./dist/*.zip "$build_dist_dir"
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
      mv -f ./dist/*.zip "$build_dist_dir"
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

mv -f ./*.zip "$build_dist_dir"


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

mv -f ./*.zip "$build_dist_dir"


# ------------------------------------------------------------------------------"
# Test operators
# ------------------------------------------------------------------------------"

echo "Building test operators"
cd "$source_dir/operators/test" || exit
[ -e dist ] && rm -rf dist
mkdir -p dist
zip -q -g ./dist/test_operations.zip ./test.py
cp "./dist/test_operations.zip" "$build_dist_dir/test_operations.zip"
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
cp "./dist/ddbstream.zip" "$build_dist_dir/ddbstream.zip"
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
cp "./dist/workflow.zip" "$build_dist_dir/workflow.zip"
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
echo "cp ./dist/sam.json $template_dist_dir/media-insights-workflowapi-stack.template"
cp dist/sam.json "$template_dist_dir"/media-insights-workflowapi-stack.template
if [ $? -ne 0 ]; then
  echo "ERROR: Failed to build workflow api template"
  exit 1
fi
echo "cp ./dist/deployment.zip $build_dist_dir/workflowapi.zip"
cp ./dist/deployment.zip "$build_dist_dir"/workflowapi.zip
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
cp "./dist/workflowstream.zip" "$build_dist_dir/workflowstream.zip"

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
echo "cp ./dist/sam.json $template_dist_dir/media-insights-dataplane-api-stack.template"
cp dist/sam.json "$template_dist_dir"/media-insights-dataplane-api-stack.template
if [ $? -ne 0 ]; then
  echo "ERROR: Failed to build dataplane api template"
  exit 1
fi
echo "cp ./dist/deployment.zip $build_dist_dir/dataplaneapi.zip"
cp ./dist/deployment.zip "$build_dist_dir"/dataplaneapi.zip
if [ $? -ne 0 ]; then
  echo "ERROR: Failed to build dataplane api template"
  exit 1
fi
rm -rf ./dist

echo "------------------------------------------------------------------------------"
echo "Copy dist to S3"
echo "------------------------------------------------------------------------------"

echo "Copying the prepared distribution to S3..."
aws s3 sync $template_dist_dir s3://$global_bucket/media_insights_engine/$version/
aws s3 sync $build_dist_dir s3://$regional_bucket-$region/media_insights_engine/$version/

echo "------------------------------------------------------------------------------"
echo "S3 packaging complete"
echo "------------------------------------------------------------------------------"

cleanup

echo ""
echo "Template to deploy:"
echo "TEMPLATE='"https://"$global_bucket"."$s3domain"/media_insights_engine/"$version"/media-insights-stack.template"'"

# Save the template URI for test automation scripts:
touch $template_dist_dir/templateUrl.txt
echo "https://"$global_bucket"."$s3domain"/media_insights_engine/"$version"/media-insights-stack.template" > ${dist_dir}/templateUrl.txt

echo "------------------------------------------------------------------------------"
echo "Done"
echo "------------------------------------------------------------------------------"

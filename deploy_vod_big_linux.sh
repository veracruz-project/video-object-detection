#!/bin/bash

BACKEND="linux"
PROFILE="debug"
VERACRUZ_PATH="$HOME/veracruz"
POLICY_GENERATOR_PATH="$VERACRUZ_PATH/workspaces/host/target/$PROFILE/generate-policy"
PAS_PATH="$VERACRUZ_PATH/workspaces/$BACKEND-host/target/$PROFILE/proxy-attestation-server"
CLIENT_PATH="$VERACRUZ_PATH/workspaces/$BACKEND-host/target/$PROFILE/veracruz-client"
SERVER_PATH="$VERACRUZ_PATH/workspaces/$BACKEND-host/target/$PROFILE/veracruz-server"
RUNTIME_MANAGER_PATH="$VERACRUZ_PATH/workspaces/$BACKEND-runtime/target/$PROFILE/runtime_manager_enclave"

PROGRAM_PATH="."
DATA_PATH="program_data"
POLICY_PATH="policy.json"
INPUT_VIDEO_PATH="in_enc.h264"
KEY_PATH="key"
IV_PATH="iv"

CA_CERT_CONF_PATH="$VERACRUZ_PATH/workspaces/ca-cert.conf"
CERT_CONF_PATH="$VERACRUZ_PATH/workspaces/cert.conf"
CA_CERT_PATH="ca_cert.pem"
CA_KEY_PATH="ca_key.pem"
PROGRAM_CLIENT_CERT_PATH="program_client_cert.pem"
PROGRAM_CLIENT_KEY_PATH="program_client_key.pem"
DATA_CLIENT_CERT_PATH="data_client_cert.pem"
DATA_CLIENT_KEY_PATH="data_client_key.pem"
S3_APP_CLIENT_CERT_PATH="s3_app_client_cert.pem"
S3_APP_CLIENT_KEY_PATH="s3_app_client_key.pem"
USER_CLIENT_CERT_PATH="user_client_cert.pem"
USER_CLIENT_KEY_PATH="user_client_key.pem"

SERVER_LOG="server.log"



echo "=============Killing components"
killall -9 proxy-attestation-server veracruz-server veracruz-client runtime_enclave_binary



echo "=============Generating certificates & keys if necessary"
if [ ! -f $CA_CERT_PATH ] || [ ! -f $CA_KEY_PATH ]; then
    echo "=============Generating $CA_CERT_PATH and $CA_KEY_PATH"
    openssl ecparam -name prime256v1 -genkey > $CA_KEY_PATH
    openssl req -x509 \
        -key $CA_KEY_PATH \
        -out $CA_CERT_PATH \
        -config $CA_CERT_CONF_PATH
fi
for i in "$PROGRAM_CLIENT_CERT_PATH $PROGRAM_CLIENT_KEY_PATH" "$DATA_CLIENT_CERT_PATH $DATA_CLIENT_KEY_PATH" "$S3_APP_CLIENT_CERT_PATH $S3_APP_CLIENT_KEY_PATH" "$USER_CLIENT_CERT_PATH $USER_CLIENT_KEY_PATH"; do
    set -- $i
    if [ ! -f $1 ] || [ ! -f $2 ]; then
        echo "=============Generating $1 and $2"
        openssl ecparam -name prime256v1 -genkey > $2
        openssl req -x509 \
            -key $2 \
            -out $1 \
            -config $CERT_CONF_PATH
    fi
done



echo "=============Generating policy"
$POLICY_GENERATOR_PATH \
    --max-memory-mib 2000 \
    --enclave-debug-mode \
    --enable-clock \
    --proxy-attestation-server-ip 127.0.0.1:3010 \
    --proxy-attestation-server-cert $CA_CERT_PATH \
    --veracruz-server-ip 127.0.0.1:3017 \
    --certificate-expiry "$(date --rfc-2822 -d 'now + 100 days')" \
    --css-file $RUNTIME_MANAGER_PATH \
    --certificate $PROGRAM_CLIENT_CERT_PATH \
    --capability "/program/:w" \
    --certificate $DATA_CLIENT_CERT_PATH \
    --capability "/program_data/:w" \
    --certificate $S3_APP_CLIENT_CERT_PATH \
    --capability "/s3_app_input/:w" \
    --certificate $USER_CLIENT_CERT_PATH \
    --capability "/program/:x,/user_input/:w,/output/:r,stdout:r,stderr:r" \
    --binary /program/detector.wasm=$PROGRAM_PATH/detector.wasm \
    --capability "/program_data/:r,/s3_app_input/:r,/user_input/:r,/program_internal/:rw,/output/:w,stdout:w,stderr:w" \
    --output-policy-file $POLICY_PATH



echo "=============Running proxy attestation server"
RUST_LOG=error $PAS_PATH \
      0.0.0.0:3010 \
      --ca-cert $CA_CERT_PATH \
      --ca-key $CA_KEY_PATH &



sleep 5
echo "=============Running veracruz server"
RUST_LOG=error $SERVER_PATH $POLICY_PATH &> $SERVER_LOG &



echo "=============Waiting for veracruz server to be ready"
grep -q "Veracruz Server running on" <(tail -f $SERVER_LOG)



echo "=============Executing veracruz client"

echo "=============Provisioning program"
RUST_LOG=error $CLIENT_PATH $POLICY_PATH \
    --program /program/detector.wasm=$PROGRAM_PATH/detector.wasm \
    --identity $PROGRAM_CLIENT_CERT_PATH \
    --key $PROGRAM_CLIENT_KEY_PATH

echo "=============Provisioning data"
RUST_LOG=error $CLIENT_PATH $POLICY_PATH \
    --data /program_data/coco.names=$DATA_PATH/coco.names \
    --data /program_data/yolov3.cfg=$DATA_PATH/yolov3.cfg \
    --data /program_data/yolov3.weights=$DATA_PATH/yolov3.weights \
    --identity $DATA_CLIENT_CERT_PATH \
    --key $DATA_CLIENT_KEY_PATH

echo "=============Provisioning video"
RUST_LOG=error $CLIENT_PATH $POLICY_PATH \
    --data /s3_app_input/in_enc.h264=$INPUT_VIDEO_PATH \
    --identity $S3_APP_CLIENT_CERT_PATH \
    --key $S3_APP_CLIENT_KEY_PATH

echo "=============Provisioning keying material"
RUST_LOG=error $CLIENT_PATH $POLICY_PATH \
    --data /user_input/key=$KEY_PATH \
    --data /user_input/iv=$IV_PATH \
    --identity $USER_CLIENT_CERT_PATH \
    --key $USER_CLIENT_KEY_PATH

echo "=============Requesting computation"
RUST_LOG=error $CLIENT_PATH $POLICY_PATH \
    --compute /program/detector.wasm \
    --identity $USER_CLIENT_CERT_PATH \
    --key $USER_CLIENT_KEY_PATH

echo "=============Querying results (stdout and stderr)"
dump=$(RUST_LOG=error $CLIENT_PATH $POLICY_PATH \
    --result stdout=- \
    --result stderr=- \
    --identity $USER_CLIENT_CERT_PATH \
    --key $USER_CLIENT_KEY_PATH \
    -n)
echo "$dump"
frame_count=$(echo "$dump" | grep "^Frames:" | awk '{print $2}')

echo "=============Querying results (predictions)"
for ((i=0;i<frame_count;i++)); do
       result_line="$result_line --result /output/prediction.$i.jpg=prediction.$i.jpg"
done
RUST_LOG=error $CLIENT_PATH $POLICY_PATH \
    $result_line \
    --identity $USER_CLIENT_CERT_PATH \
    --key $USER_CLIENT_KEY_PATH

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
INPUT_VIDEO_PATH="in.h264"

CA_CERT_CONF_PATH="$VERACRUZ_PATH/workspaces/ca-cert.conf"
CERT_CONF_PATH="$VERACRUZ_PATH/workspaces/cert.conf"
CA_CERT_PATH="ca_cert.pem"
CA_KEY_PATH="ca_key.pem"
PROGRAM_CLIENT_CERT_PATH="program_client_cert.pem"
PROGRAM_CLIENT_KEY_PATH="program_client_key.pem"
DATA_CLIENT_CERT_PATH="data_client_cert.pem"
DATA_CLIENT_KEY_PATH="data_client_key.pem"
VIDEO_CLIENT_CERT_PATH="video_client_cert.pem"
VIDEO_CLIENT_KEY_PATH="video_client_key.pem"
RESULT_CLIENT_CERT_PATH="result_client_cert.pem"
RESULT_CLIENT_KEY_PATH="result_client_key.pem"

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
for i in "$PROGRAM_CLIENT_CERT_PATH $PROGRAM_CLIENT_KEY_PATH" "$DATA_CLIENT_CERT_PATH $DATA_CLIENT_KEY_PATH" "$VIDEO_CLIENT_CERT_PATH $VIDEO_CLIENT_KEY_PATH" "$RESULT_CLIENT_CERT_PATH $RESULT_CLIENT_KEY_PATH"; do
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
    --certificate $VIDEO_CLIENT_CERT_PATH \
    --capability "/video_input/:w" \
    --certificate $RESULT_CLIENT_CERT_PATH \
    --capability "/program/:x,/output/:r,stdout:r,stderr:r" \
    --binary /program/detector.wasm=$PROGRAM_PATH/detector.wasm \
    --capability "/program_data/:r,/video_input/:r,/program_internal/:rw,/output/:w,stdout:w,stderr:w" \
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
    --data /video_input/in.h264=$INPUT_VIDEO_PATH \
    --identity $VIDEO_CLIENT_CERT_PATH \
    --key $VIDEO_CLIENT_KEY_PATH

echo "=============Requesting computation"
RUST_LOG=error $CLIENT_PATH $POLICY_PATH \
    --compute /program/detector.wasm \
    --identity $RESULT_CLIENT_CERT_PATH \
    --key $RESULT_CLIENT_KEY_PATH

echo "=============Querying results (stdout and stderr)"
dump=$(RUST_LOG=error $CLIENT_PATH $POLICY_PATH \
    --result stdout=- \
    --result stderr=- \
    --identity $RESULT_CLIENT_CERT_PATH \
    --key $RESULT_CLIENT_KEY_PATH \
    -n)
echo "$dump"
frame_count=$(echo "$dump" | grep "^Frames:" | awk '{print $2}')

echo "=============Querying results (predictions)"
for ((i=0;i<frame_count;i++)); do
       result_line="$result_line --result /output/prediction.$i.jpg=prediction.$i.jpg"
done
RUST_LOG=error $CLIENT_PATH $POLICY_PATH \
    $result_line \
    --identity $RESULT_CLIENT_CERT_PATH \
    --key $RESULT_CLIENT_KEY_PATH

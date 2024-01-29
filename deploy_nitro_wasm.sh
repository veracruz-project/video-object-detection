#!/bin/bash

# Deploy VOD on Nitro as a WASM binary

BACKEND="nitro"
PROFILE="${PROFILE:-debug}"
VERACRUZ_PATH="${VERACRUZ_PATH:-$HOME/veracruz}"

# Binaries
POLICY_GENERATOR_PATH="${POLICY_GENERATOR_PATH:-$VERACRUZ_PATH/workspaces/host/target/$PROFILE/generate-policy}"
CLIENT_PATH="${CLIENT_PATH:-$VERACRUZ_PATH/workspaces/$BACKEND-host/target/$PROFILE/veracruz-client}"
SERVER_PATH="${SERVER_PATH:-$VERACRUZ_PATH/workspaces/$BACKEND-host/target/$PROFILE/$BACKEND-veracruz-server}"
EIF_PATH="${EIF_PATH:-$VERACRUZ_PATH/workspaces/$BACKEND-runtime/runtime_manager.eif}"
PCR0_PATH="${PCR0_PATH:-$VERACRUZ_PATH/workspaces/$BACKEND-runtime/PCR0}"

# Attestation
VTS_PATH="/opt/veraison/vts"
PROVISIONING_PATH="/opt/veraison/provisioning"
PAS_PATH="/opt/veraison/proxy_attestation_server"

# Addresses and ports
PROVISIONING_SERVER_ADDRESS="localhost"
PROVISIONING_SERVER_PORT="8888"
PAS_ADDRESS="127.0.0.1"
PAS_PORT="3010"
VC_SERVER_ADDRESS="127.0.0.1"
VC_SERVER_PORT="3017"

# Provisions
PROGRAM_DIR="${PROGRAM_DIR:-program}"
PROGRAM_DATA_DIR="${PROGRAM_DATA_DIR:-program_data}"
VIDEO_INPUT_DIR="${VIDEO_INPUT_DIR:-video_input}"
OUTPUT_DIR="${OUTPUT_DIR:-output}"
PROGRAM_BASENAME="detector.wasm"
PROGRAM_PATH_LOCAL="${PROGRAM_PATH_LOCAL:-./$PROGRAM_BASENAME}"
PROGRAM_PATH_REMOTE="${PROGRAM_PATH_REMOTE:-./$PROGRAM_DIR/$PROGRAM_BASENAME}"
COCO_BASENAME="coco.names"
COCO_PATH_LOCAL="${COCO_PATH_LOCAL:-$PROGRAM_DATA_DIR/$COCO_BASENAME}"
COCO_PATH_REMOTE="${COCO_PATH_REMOTE:-./$PROGRAM_DATA_DIR/$COCO_BASENAME}"
YOLOV3_CFG_BASENAME="yolov3.cfg"
YOLOV3_CFG_PATH_LOCAL="${YOLOV3_CFG_PATH_LOCAL:-$PROGRAM_DATA_DIR/$YOLOV3_CFG_BASENAME}"
YOLOV3_CFG_PATH_REMOTE="${YOLOV3_CFG_PATH_REMOTE:-./$PROGRAM_DATA_DIR/$YOLOV3_CFG_BASENAME}"
YOLOV3_WEIGHTS_BASENAME="yolov3.weights"
YOLOV3_WEIGHTS_PATH_LOCAL="${YOLOV3_WEIGHTS_PATH_LOCAL:-$PROGRAM_DATA_DIR/$YOLOV3_WEIGHTS_BASENAME}"
YOLOV3_WEIGHTS_PATH_REMOTE="${YOLOV3_WEIGHTS_PATH_REMOTE:-./$PROGRAM_DATA_DIR/$YOLOV3_WEIGHTS_BASENAME}"
INPUT_VIDEO_BASENAME="in.h264"
INPUT_VIDEO_PATH_LOCAL="${INPUT_VIDEO_PATH_LOCAL:-$VIDEO_INPUT_DIR/$INPUT_VIDEO_BASENAME}"
INPUT_VIDEO_PATH_REMOTE="${INPUT_VIDEO_PATH_REMOTE:-./$VIDEO_INPUT_DIR/$INPUT_VIDEO_BASENAME}"

# PKI
CA_CERT_CONF_PATH="${CA_CERT_CONF_PATH:-$VERACRUZ_PATH/workspaces/ca-cert.conf}"
CERT_CONF_PATH="${CERT_CONF_PATH:-$VERACRUZ_PATH/workspaces/cert.conf}"
CA_CERT_PATH="CACert.pem" # This value is hardcoded in the proxy attestation server
CA_KEY_PATH="CAKey.pem" # This value is hardcoded in the proxy attestation server
PROGRAM_CLIENT_CERT_PATH="program_client_cert.pem"
PROGRAM_CLIENT_KEY_PATH="program_client_key.pem"
DATA_CLIENT_CERT_PATH="data_client_cert.pem"
DATA_CLIENT_KEY_PATH="data_client_key.pem"
VIDEO_CLIENT_CERT_PATH="video_client_cert.pem"
VIDEO_CLIENT_KEY_PATH="video_client_key.pem"
RESULT_CLIENT_CERT_PATH="result_client_cert.pem"
RESULT_CLIENT_KEY_PATH="result_client_key.pem"

POLICY_PATH="${POLICY_PATH:-policy.json}"

PROXY_CLEANUP_SCRIPT_PATH="${PROXY_CLEANUP_SCRIPT_PATH:-$VERACRUZ_PATH/proxy_cleanup.sh}"

NITRO_LOG="${NITRO_LOG:-nitro.log}"
SERVER_LOG="${SERVER_LOG:-server.log}"
SERVER_ATTEMPTS="${SERVER_ATTEMPTS:-60}"
SERVER_TIMEOUT="${SERVER_TIMEOUT:-5}"

# Parse arguments
ARGS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --serverless)
      # Don't run Veracruz-Server as part of this script. Useful when running
      # Veracruz-Server in a debugger
      SERVERLESS=1
      shift
      ;;
    -*|--*)
      echo "Unknown option $1"
      exit 1
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done
set -- "${ARGS[@]}"



echo "=============Killing components"
killall -9 proxy_attestation_server $BACKEND-veracruz-server veracruz-client runtime_enclave_binary
$PROXY_CLEANUP_SCRIPT_PATH || true
nitro-cli terminate-enclave --all || exit 1



echo "=============Generating certificates & keys if necessary"
if [ ! -f $CA_CERT_PATH ] || [ ! -f $CA_KEY_PATH ]; then
    echo "=============Generating $CA_CERT_PATH and $CA_KEY_PATH"
    openssl ecparam -name prime256v1 -noout -genkey > $CA_KEY_PATH
    openssl req -x509 \
        -key $CA_KEY_PATH \
        -out $CA_CERT_PATH \
        -config $CA_CERT_CONF_PATH
fi
for i in "$PROGRAM_CLIENT_CERT_PATH $PROGRAM_CLIENT_KEY_PATH" "$DATA_CLIENT_CERT_PATH $DATA_CLIENT_KEY_PATH" "$VIDEO_CLIENT_CERT_PATH $VIDEO_CLIENT_KEY_PATH" "$RESULT_CLIENT_CERT_PATH $RESULT_CLIENT_KEY_PATH"; do
    set -- $i
    if [ ! -f $1 ] || [ ! -f $2 ]; then
        echo "=============Generating $1 and $2"
        openssl ecparam -name prime256v1 -genkey > $2 || exit 1
        openssl req -x509 \
            -key $2 \
            -out $1 \
            -config $CERT_CONF_PATH || exit 1
    fi
done



echo "=============Generating policy"
$POLICY_GENERATOR_PATH \
    --max-memory-mib 2000 \
    --proxy-attestation-server-ip $PAS_ADDRESS:$PAS_PORT \
    --proxy-attestation-server-cert $CA_CERT_PATH \
    --veracruz-server-ip $VC_SERVER_ADDRESS:$VC_SERVER_PORT \
    --certificate-expiry "$(date --rfc-2822 -d 'now + 100 days')" \
    --pcr-file $PCR0_PATH \
    --certificate "$PROGRAM_CLIENT_CERT_PATH => ./$PROGRAM_DIR/:w" \
    --certificate "$DATA_CLIENT_CERT_PATH => ./$PROGRAM_DATA_DIR/:w" \
    --certificate "$VIDEO_CLIENT_CERT_PATH => ./$VIDEO_INPUT_DIR/:w" \
    --certificate "$RESULT_CLIENT_CERT_PATH => ./$PROGRAM_DIR/:x,./$OUTPUT_DIR/:r" \
    --program-binary "$PROGRAM_PATH_REMOTE=$PROGRAM_PATH_LOCAL => ./$PROGRAM_DATA_DIR/:r,./$VIDEO_INPUT_DIR/:r,./program_internal/:rw,./$OUTPUT_DIR/:w" \
    --output-policy-file $POLICY_PATH || exit 1



echo "=============Running proxy attestation service"
pushd "$PWD"
cd $VTS_PATH && $VTS_PATH/vts &
cd $PROVISIONING_PATH && $PROVISIONING_PATH/provisioning &
popd
$PAS_PATH -l $PAS_ADDRESS:$PAS_PORT &
sleep 5



echo "=============Provisioning attestation personalities"
curl -X POST -H 'Content-Type: application/corim-unsigned+cbor; profile=http://arm.com/psa/iot/1' --data-binary "@/opt/veraison/psa_corim.cbor" $PROVISIONING_SERVER_ADDRESS:$PROVISIONING_SERVER_PORT/endorsement-provisioning/v1/submit || exit 1
curl -X POST -H 'Content-Type: application/corim-unsigned+cbor; profile=http://aws.com/nitro' --data-binary "@/opt/veraison/nitro_corim.cbor" $PROVISIONING_SERVER_ADDRESS:$PROVISIONING_SERVER_PORT/endorsement-provisioning/v1/submit || exit 1



if [ -z $SERVERLESS ]; then 
    echo "=============Running veracruz server"
    RUST_LOG=error RUNTIME_MANAGER_EIF_PATH=$EIF_PATH RUNTIME_ENCLAVE_BINARY_PATH=$RUNTIME_MANAGER_PATH $SERVER_PATH $POLICY_PATH &> $SERVER_LOG &
fi



echo "=============Waiting for veracruz server to be ready"
for ((i=0;;i++)); do
    if [ $i -ge $SERVER_ATTEMPTS ]; then
        echo "Server not ready after ${i} attempts. See log for more details. Terminating"
        exit 1
    fi
    echo -n | timeout $SERVER_TIMEOUT telnet $VC_SERVER_ADDRESS $VC_SERVER_PORT 2>/dev/null | grep "^Connected to" && break
    sleep 1
done



echo "=============Attaching to nitro console"
enclave_id=`nitro-cli describe-enclaves | sed -nr "s/^.*EnclaveID[^0-9a-z\-]+([0-9a-z\-]+).*$/\1/p"`
nitro-cli console --enclave-id $enclave_id &> $NITRO_LOG &



echo "=============Executing veracruz client"

echo "=============Provisioning program"
RUST_LOG=error $CLIENT_PATH $POLICY_PATH \
    --program $PROGRAM_PATH_REMOTE=$PROGRAM_PATH_LOCAL \
    --identity $PROGRAM_CLIENT_CERT_PATH \
    --key $PROGRAM_CLIENT_KEY_PATH || exit 1

echo "=============Provisioning data"
RUST_LOG=error $CLIENT_PATH $POLICY_PATH \
    --data $COCO_PATH_REMOTE=$COCO_PATH_LOCAL \
    --data $YOLOV3_CFG_PATH_REMOTE=$YOLOV3_CFG_PATH_LOCAL \
    --data $YOLOV3_WEIGHTS_PATH_REMOTE=$YOLOV3_WEIGHTS_PATH_LOCAL \
    --identity $DATA_CLIENT_CERT_PATH \
    --key $DATA_CLIENT_KEY_PATH || exit 1

echo "=============Provisioning video"
RUST_LOG=error $CLIENT_PATH $POLICY_PATH \
    --data $INPUT_VIDEO_PATH_REMOTE=$INPUT_VIDEO_PATH_LOCAL \
    --identity $VIDEO_CLIENT_CERT_PATH \
    --key $VIDEO_CLIENT_KEY_PATH || exit 1

echo "=============Requesting computation"
RUST_LOG=error $CLIENT_PATH $POLICY_PATH \
    --compute $PROGRAM_PATH_REMOTE \
    --identity $RESULT_CLIENT_CERT_PATH \
    --key $RESULT_CLIENT_KEY_PATH || exit 1

echo "=============Querying results (predictions)"
RUST_LOG=error $CLIENT_PATH $POLICY_PATH \
    --result "./$OUTPUT_DIR/prediction.0.jpg=prediction.0.jpg" \
    --identity $RESULT_CLIENT_CERT_PATH \
    --key $RESULT_CLIENT_KEY_PATH



echo "=============Killing components"
killall -9 proxy_attestation_server $BACKEND-veracruz-server veracruz-client runtime_enclave_binary
$PROXY_CLEANUP_SCRIPT_PATH || true
nitro-cli terminate-enclave --all || exit 1

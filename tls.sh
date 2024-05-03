#!/usr/bin/env bash
sudo apt-get install golang-cfssl
cat << EOF | tee -a ca-csr.json
{
    "CN": "ChirpStack CA",
    "key": {
        "algo": "rsa",
        "size": 4096
    }
}
EOF
cat << EOF | tee -a ca-config.json
{
    "signing": {
        "default": {
            "expiry": "8760h"
        },
        "profiles": {
            "server": {
                "expiry": "8760h",
                "usages": [
                    "signing",
                    "key encipherment",
                    "server auth"
                ]
            }
        }
    }
}
EOF
cfssl gencert -initca ca-csr.json | cfssljson -bare ca

cat << EOF | tee -a mqtt-server.json
{
    "CN": "localhost",
    "hosts": [
        "localhost"
    ],
    "key": {
        "algo": "rsa",
        "size": 4096
    }
}
EOF
cfssl gencert -ca ca.pem -ca-key ca-key.pem -config ca-config.json -profile server mqtt-server.json | cfssljson -bare mqtt-server
chirpstack_toml="./configuration/chirpstack/chirpstack.toml"
if grep -q "you-must-replace-this" ${chirpstack_toml}; then
    secret=$(openssl rand -base64 32)
    sed -i "s|you-must-replace-this|${secret}|g" ${chirpstack_toml}
else
    echo "Skip secret key replacement"
fi

if grep -q "\[gateway\]" ${chirpstack_toml}; then
    echo "Skip MQTT Gateway TLS configuration"
else
    cat << EOF | tee -a ${chirpstack_toml}
[gateway]
client_cert_lifetime="12months"
ca_cert="/etc/chirpstack/certs/ca.pem"
ca_key="/etc/chirpstack/certs/ca-key.pem"
EOF
    echo "MQTT Gateway TLS configuration added"
fi

if grep -q "\[integration.mqtt.client\]" ${chirpstack_toml}; then
    echo "Skip MQTT Network Server TLS configuration"
else
    cat << EOF | tee -a ${chirpstack_toml}
[integration.mqtt.client]
client_cert_lifetime="12months"
ca_cert="/etc/chirpstack/certs/ca.pem"
ca_key="/etc/chirpstack/certs/ca-key.pem"
EOF
    echo "MQTT Network Server TLS configuration added"
fi
chirpstack_dir="./configuration/chirpstack"
mkdir -p "${chirpstack_dir}/certs"
cp -r ca*.pem ${chirpstack_dir}/certs
mosquitto_dir="./configuration/mosquitto/config"
sudo chown -R 1000:1000 ./configuration/mosquitto
mkdir -p "${mosquitto_dir}/certs"
cp -r ca.pem mqtt-server-key.pem mqtt-server.pem "${mosquitto_dir}/certs"

if [ -e "${mosquitto_dir}/acl" ]; then
    echo "Skip ACL configuration"
else
    cat << EOF | tee -a "${mosquitto_dir}/acl"
pattern readwrite +/gateway/%u/#
pattern readwrite application/%u/#
EOF
    sudo chmod 700 "${mosquitto_dir}/acl"
    echo "ACL configuration added"
fi

if grep -q "listener 8883 0.0.0.0" "${mosquitto_dir}/mosquitto.conf"; then
    echo "Skip MQTT TLS configuration"
else
    cat << EOF | tee -a "${mosquitto_dir}/mosquitto.conf"
listener 8883 0.0.0.0
cafile /mosquitto/config/certs/ca.pem
certfile /mosquitto/config/certs/mqtt-server.pem
keyfile /mosquitto/config/certs/mqtt-server-key.pem
allow_anonymous true
require_certificate false
use_identity_as_username true
acl_file /mosquitto/config/acl
EOF
    echo "MQTT TLS configuration added"
fi
rm -r *.json *.pem *.csr

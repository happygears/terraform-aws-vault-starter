#!/usr/bin/env bash

imds_token=$( curl -Ss -H "X-aws-ec2-metadata-token-ttl-seconds: 30" -XPUT 169.254.169.254/latest/api/token )
instance_id=$( curl -Ss -H "X-aws-ec2-metadata-token: $imds_token" 169.254.169.254/latest/meta-data/instance-id )
local_ipv4=$( curl -Ss -H "X-aws-ec2-metadata-token: $imds_token" 169.254.169.254/latest/meta-data/local-ipv4 )
ARCH=$(dpkg --print-architecture)

# install package

curl -fsSL https://apt.releases.hashicorp.com/gpg | apt-key add -
apt-add-repository "deb [arch=$ARCH] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
apt-get update
apt-get install -y vault=${vault_version} awscli jq

echo "Configuring system time"
timedatectl set-timezone UTC

# removing any default installation files from /opt/vault/tls/
rm -rf /opt/vault/tls/*

# /opt/vault/tls should be readable by all users of the system
chmod 0755 /opt/vault/tls

# vault-key.pem should be readable by the vault group only
touch /opt/vault/tls/vault-key.pem
chown root:vault /opt/vault/tls/vault-key.pem
chmod 0640 /opt/vault/tls/vault-key.pem

secret_result=$(aws secretsmanager get-secret-value --secret-id ${secrets_manager_arn} --region ${region} --output text --query SecretString)

jq -r .vault_cert <<< "$secret_result" | base64 -d > /opt/vault/tls/vault-cert.pem

jq -r .vault_ca <<< "$secret_result" | base64 -d > /opt/vault/tls/vault-ca.pem

jq -r .vault_pk <<< "$secret_result" | base64 -d > /opt/vault/tls/vault-key.pem

cat << EOF > /etc/vault.d/vault.hcl
disable_performance_standby = true
ui = true
disable_mlock = true

storage "raft" {
  path    = "/opt/vault/data"
  node_id = "$instance_id"
  retry_join {
    auto_join = "provider=aws region=${region} tag_key=${name}-vault tag_value=server"
    auto_join_scheme = "https"
    leader_tls_servername = "${leader_tls_servername}"
    leader_ca_cert_file = "/opt/vault/tls/vault-ca.pem"
    leader_client_cert_file = "/opt/vault/tls/vault-cert.pem"
    leader_client_key_file = "/opt/vault/tls/vault-key.pem"
  }
}

cluster_addr = "https://$local_ipv4:8201"
api_addr = "https://$local_ipv4:8200"

listener "tcp" {
  address            = "0.0.0.0:8200"
  tls_disable        = false
  tls_cert_file      = "/opt/vault/tls/vault-cert.pem"
  tls_key_file       = "/opt/vault/tls/vault-key.pem"
  tls_client_ca_file = "/opt/vault/tls/vault-ca.pem"
}

seal "awskms" {
  region     = "${region}"
  kms_key_id = "${kms_key_arn}"
}

EOF

# Define log level
cat << EOF >> /etc/vault.d/vault.env
VAULT_LOG_LEVEL=info
EOF

# vault.hcl should be readable by the vault group only
chown root:root /etc/vault.d
chown root:vault /etc/vault.d/*
chmod 640 /etc/vault.d/*

systemctl enable vault
systemctl start vault

echo "Setup Vault profile"
cat <<PROFILE | sudo tee /etc/profile.d/vault.sh
export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="/opt/vault/tls/vault-ca.pem"
PROFILE

# START SNAPSHOT LOGIC
# Add cron-job to perform snapshots and upload them to S3 bucket
# only when snapshots are enabled so bucket ID is not empty
if test -n "${snapshots_bucket_id}"
then
echo 'export VAULT_SNAPSHOTS_BUCKET="${snapshots_bucket_id}"' >> /etc/profile.d/vault.sh
# Create snapshot cron-job script
cat << SNAPSHOT > /usr/local/bin/vault-snapshot.sh
#!/usr/bin/env bash
source /etc/profile.d/vault.sh

MYNAME=\$(basename "\$0")

# Only run this on active node in a cluster
vault status | grep -q Mode.*active || exit 0

if VAULT_TOKEN=\$(vault login -token-only -method=aws role=vault-node-access header_value=vault.netspyglass.com) 2>/tmp/\$MYNAME.err
then
  export VAULT_TOKEN
else
  logger -t "\$MYNAME[\$$]" -p daemon.error "ERROR can not log in to Vault: \$(sed ':a;N;$!ba;s/\n/\n /g' /tmp/\$MYNAME.err)"
  exit 1
fi

# Take snapshot and send it to AWS S3 backup
rm -f /tmp/raft.snap /tmp/\$MYNAME.err
vault operator raft snapshot save /tmp/raft.snap 2>/tmp/\$MYNAME.err && \
aws --output=text s3api put-object --bucket ${snapshots_bucket_id} \
  --key raft.snap --body /tmp/raft.snap \
  --tagging "customer=happygears&component=vault&environment=prod&source=terraform" 2>>/tmp/\$MYNAME.err >/tmp/\$MYNAME.out
if test -s "/tmp/\$MYNAME.err"
then
  logger -t "\$MYNAME[\$$]" -p daemon.error "ERROR snapshot failed: \$(sed ':a;N;$!ba;s/\n/\n /g' /tmp/\$MYNAME.err)"
else
  logger -t "\$MYNAME[\$$]" -p daemon.info "INFO snapshot finished and uploaded to s3://${snapshots_bucket_id}/raft.snap : \$(sed ':a;N;$!ba;s/\n/\n /g' /tmp/\$MYNAME.out)"
fi
rm -f /tmp/raft.snap /tmp/\$MYNAME.{err,out}
SNAPSHOT
chmod 755 /usr/local/bin/vault-snapshot.sh
# Create cron-job to run snapshots
cat << CRON > /etc/cron.d/vault
# Take snapshot
0 */2 * * * root /usr/local/bin/vault-snapshot.sh >/var/log/vault-snapshot.log 2>&1
CRON
fi
# END SNAPSHOT LOGIC


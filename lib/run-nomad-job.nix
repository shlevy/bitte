{ name, json, writeShellScriptBin }:
writeShellScriptBin "nomad-run" ''
  echo running ${json}

  set -euo pipefail

  vault token lookup "$(vault print token)" &> /dev/null \
  || vault login -method github -path github-employees -no-print

  aws s3 ls &> /dev/null \
  || (
    echo "Generating AWS Credentials and setting them in $AWS_PROFILE ..."
    creds="$(vault read -format json aws/creds/developer)"
    aws configure set --profile "$AWS_PROFILE" aws_access_key_id "$( echo "$creds" | jq -r -e .data.access_key )"
    aws configure set --profile "$AWS_PROFILE" aws_secret_access_key "$(echo "$creds" | jq -r -e .data.secret_key)"
    echo "Waiting ten seconds for AWS to catch up..."
    sleep 10
  )

  NOMAD_TOKEN="$(vault read -field secret_id nomad/creds/developer)"
  export NOMAD_TOKEN

  CONSUL_HTTP_TOKEN="$(vault read -field token consul/creds/developer)"
  export CONSUL_HTTP_TOKEN

  cache="$(nix eval ".#clusters.$BITTE_CLUSTER.proto.config.cluster.s3Cache" --raw)"

  echo "Copying closure to the binary cache..."
  nix copy --to "$cache&secret-key=secrets/nix-secret-key-file" ${json}

  jq --arg token "$CONSUL_HTTP_TOKEN" '.Job.ConsulToken = $token' < ${json} \
  | curl -f \
    -X POST \
    -H "X-Nomad-Token: $NOMAD_TOKEN" \
    -H "X-Vault-Token: $(vault print token)" \
    -d @- \
    "$NOMAD_ADDR/v1/jobs"
''

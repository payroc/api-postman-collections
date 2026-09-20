#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
environment_dir="$script_dir/environment"
collection_dir="$script_dir/collections"
spec_dir="$script_dir/spec"
environment_template_file="$environment_dir/payroc-uat.postman_environment.json"
postman_api_url="https://api.postman.com"
workspace_name="Payroc API"

prompt_secret() {
  local prompt="$1"
  local value

  read -r -s -p "$prompt" value
  printf '\n' >&2
  printf '%s' "$value"
}

json_get() {
  local json_input="$1"
  local ruby_code="$2"
  JSON_INPUT="$json_input" ruby -rjson -e "$ruby_code"
}

if [[ -n "${POSTMAN_API_KEY:-}" ]]; then
  postman_api_key="$POSTMAN_API_KEY"
else
  postman_api_key="$(prompt_secret "Please enter your Postman API Key (the one from your Postman account settings, e.g. PMAK-xxxxxxxxxxxxxxxxxxxxxxxx-XXXX): ")"
fi

if [[ -n "${PAYROC_API_KEY:-}" ]]; then
  payroc_api_key="$PAYROC_API_KEY"
else
  payroc_api_key="$(prompt_secret "Please enter your Payroc API Key (the one provided to you by Payroc): ")"
fi

payroc_environment="${PAYROC_ENV:-uat}"

case "$payroc_environment" in
  uat|test)
    environment_name="Payroc UAT"
    payroc_base_url="${PAYROC_BASE_URL:-https://api.uat.payroc.com/v1}"
    payroc_identity_base_url="${PAYROC_IDENTITY_BASE_URL:-https://identity.uat.payroc.com}"
    ;;
  production|prod)
    environment_name="Payroc Production"
    payroc_base_url="${PAYROC_BASE_URL:-https://api.payroc.com/v1}"
    payroc_identity_base_url="${PAYROC_IDENTITY_BASE_URL:-https://identity.payroc.com}"
    ;;
  *)
    echo "Unsupported PAYROC_ENV '$payroc_environment'. Use 'uat' or 'production'." >&2
    exit 1
    ;;
esac

headers=(
  -H "X-Api-Key: $postman_api_key"
  -H "Content-Type: application/json"
)

curl_json() {
  local method="$1"
  local url="$2"
  local body_file="${3:-}"

  if [[ -n "$body_file" ]]; then
    curl -fsS -X "$method" "${headers[@]}" --data-binary "@$body_file" "$url"
  else
    curl -fsS -X "$method" "${headers[@]}" "$url"
  fi
}

make_wrapped_json_file() {
  local wrapper_key="$1"
  local source_file="$2"
  local temp_file

  temp_file="$(mktemp)"
  WRAPPER_KEY="$wrapper_key" FILE_PATH="$source_file" OUTPUT_PATH="$temp_file" ruby -rjson -e '
    key = ENV.fetch("WRAPPER_KEY")
    path = ENV.fetch("FILE_PATH")
    output = ENV.fetch("OUTPUT_PATH")
    data = JSON.parse(File.read(path))
    File.write(output, JSON.generate({ key => data }))
  '

  printf '%s' "$temp_file"
}

make_json_temp_file() {
  local temp_file

  temp_file="$(mktemp)"
  cat >"$temp_file"
  printf '%s' "$temp_file"
}

make_environment_file() {
  local temp_file

  temp_file="$(mktemp)"
  TEMPLATE_ENV_FILE="$environment_template_file" \
  OUTPUT_PATH="$temp_file" \
  PAYROC_ENV_NAME="$environment_name" \
  PAYROC_BASE_URL_VALUE="$payroc_base_url" \
  PAYROC_IDENTITY_BASE_URL_VALUE="$payroc_identity_base_url" \
  PAYROC_API_KEY_VALUE="$payroc_api_key" \
  ruby -rjson -e '
    path = ENV.fetch("TEMPLATE_ENV_FILE")
    output = ENV.fetch("OUTPUT_PATH")
    data = JSON.parse(File.read(path))

    replacements = {
      "name" => ENV.fetch("PAYROC_ENV_NAME"),
      "baseUrl" => ENV.fetch("PAYROC_BASE_URL_VALUE"),
      "identityBaseUrl" => ENV.fetch("PAYROC_IDENTITY_BASE_URL_VALUE"),
      "api-key" => ENV.fetch("PAYROC_API_KEY_VALUE")
    }

    data["name"] = replacements.fetch("name")

    data.fetch("values").each do |entry|
      next unless replacements.key?(entry["key"])

      entry["value"] = replacements.fetch(entry["key"])
    end

    File.write(output, JSON.pretty_generate(data) + "\n")
  '

  printf '%s' "$temp_file"
}

urlencode() {
  ruby -ruri -e 'puts URI.encode_www_form_component(ARGV[0])' "$1"
}

read_spec_metadata() {
  local metadata_file

  metadata_file="$(mktemp)"
  SPEC_DIR="$spec_dir" OUTPUT_PATH="$metadata_file" ruby -rjson -ryaml -e '
    spec_dir = ENV.fetch("SPEC_DIR")
    output = ENV.fetch("OUTPUT_PATH")

    files = Dir.glob(File.join(spec_dir, "**", "*"), File::FNM_DOTMATCH)
      .select { |path| File.file?(path) }
      .reject { |path| File.basename(path).start_with?(".") }
      .sort

    root_file = files.find { |path| File.basename(path) =~ /\A(openapi|swagger|spec)/i } ||
      files.find { |path| [".yaml", ".yml", ".json"].include?(File.extname(path).downcase) }

    abort("No spec files found in #{spec_dir}") unless root_file

    raw = File.read(root_file)
    parsed =
      case File.extname(root_file).downcase
      when ".json"
        JSON.parse(raw)
      else
        YAML.safe_load(raw, aliases: true)
      end

    version = parsed["openapi"] || parsed["swagger"] || ""
    type =
      case version
      when /\A3\.1/
        "OPENAPI:3.1"
      when /\A3\.0/
        "OPENAPI:3.0"
      when /\A2(\.0)?\z/, /\Aswagger:\s*2/i
        "OPENAPI:2.0"
      else
        abort("Unsupported or unknown spec version: #{version.inspect}")
      end

    title = parsed.dig("info", "title")
    relative_root = root_file.delete_prefix(spec_dir + "/")

    File.write(output, JSON.generate({
      "name" => "#{title || File.basename(relative_root, ".*")} Specification",
      "type" => type,
      "rootFile" => relative_root
    }))
  '

  cat "$metadata_file"
  rm -f "$metadata_file"
}

make_spec_payload_file() {
  local temp_file

  temp_file="$(mktemp)"
  SPEC_DIR="$spec_dir" SPEC_METADATA_JSON="$1" OUTPUT_PATH="$temp_file" ruby -rjson -e '
    spec_dir = ENV.fetch("SPEC_DIR")
    metadata = JSON.parse(ENV.fetch("SPEC_METADATA_JSON"))
    output = ENV.fetch("OUTPUT_PATH")

    files = Dir.glob(File.join(spec_dir, "**", "*"), File::FNM_DOTMATCH)
      .select { |path| File.file?(path) }
      .reject { |path| File.basename(path).start_with?(".") }
      .sort
      .map do |path|
        {
          "path" => path.delete_prefix(spec_dir + "/"),
          "content" => File.read(path)
        }
      end

    File.write(output, JSON.generate({
      "name" => metadata.fetch("name"),
      "type" => metadata.fetch("type"),
      "files" => files
    }))
  '

  printf '%s' "$temp_file"
}

existing_workspaces="$(curl_json GET "$postman_api_url/workspaces")"
workspace_id="$(
  json_get "$existing_workspaces" '
    data = JSON.parse(ENV.fetch("JSON_INPUT"))
    workspace = data.fetch("workspaces", []).find { |entry| entry["name"] == "Payroc API" }
    puts(workspace ? workspace["id"] : "")
  '
)"

if [[ -n "$workspace_id" ]]; then
  echo "Identified Workspace '$workspace_name' with Id $workspace_id"
else
  workspace_payload_file="$(
    ruby -rjson -e '
      puts JSON.generate({
        "workspace" => {
          "name" => "Payroc API",
          "type" => "personal",
          "description" => "Workspace for Payroc API"
        }
      })
    '
  | make_json_temp_file
  )"

  echo "Creating Workspace '$workspace_name'..."
  new_workspace="$(curl_json POST "$postman_api_url/workspaces" "$workspace_payload_file")"
  rm -f "$workspace_payload_file"
  workspace_id="$(
    json_get "$new_workspace" '
      data = JSON.parse(ENV.fetch("JSON_INPUT"))
      puts data.fetch("workspace").fetch("id")
    '
  )"
  echo "New Workspace '$workspace_name' has Id $workspace_id"
fi

echo "Updating Workspace $workspace_name"
workspace_query="?workspace=$workspace_id"

existing_environments="$(curl_json GET "$postman_api_url/environments$workspace_query")"

shopt -s nullglob

generated_environment_file="$(make_environment_file)"
environment_files=("$generated_environment_file")

for extra_environment_path in "$environment_dir"/*.json; do
  if [[ "$extra_environment_path" != "$environment_template_file" ]]; then
    environment_files+=("$extra_environment_path")
  fi
done

for environment_path in "${environment_files[@]}"; do
  environment_name="$(
    FILE_PATH="$environment_path" ruby -rjson -e '
      data = JSON.parse(File.read(ENV.fetch("FILE_PATH")))
      puts data.fetch("name")
    '
  )"

  resource_id="$(
    JSON_INPUT="$existing_environments" TARGET_NAME="$environment_name" ruby -rjson -e '
      data = JSON.parse(ENV.fetch("JSON_INPUT"))
      environment = data.fetch("environments", []).find { |entry| entry["name"] == ENV.fetch("TARGET_NAME") }
      puts(environment ? environment["id"] : "")
    '
  )"

  if [[ -n "$resource_id" ]]; then
    echo "Deleting environment '$environment_name'..."
    curl_json DELETE "$postman_api_url/environments/$resource_id" >/dev/null
  fi

  request_body_file="$(make_wrapped_json_file "environment" "$environment_path")"
  echo "Creating environment '$environment_name'..."
  curl_json POST "$postman_api_url/environments$workspace_query" "$request_body_file" >/dev/null
  rm -f "$request_body_file"
done

rm -f "$generated_environment_file"

echo "Environments imported."

existing_collections="$(curl_json GET "$postman_api_url/collections$workspace_query")"

for collection_path in "$collection_dir"/*.json; do
  collection_name="$(
    FILE_PATH="$collection_path" ruby -rjson -e '
      data = JSON.parse(File.read(ENV.fetch("FILE_PATH")))
      puts data.fetch("info").fetch("name")
    '
  )"

  resource_id="$(
    JSON_INPUT="$existing_collections" TARGET_NAME="$collection_name" ruby -rjson -e '
      data = JSON.parse(ENV.fetch("JSON_INPUT"))
      collection = data.fetch("collections", []).find { |entry| entry["name"] == ENV.fetch("TARGET_NAME") }
      puts(collection ? collection["id"] : "")
    '
  )"

  if [[ -n "$resource_id" ]]; then
    echo "Deleting collection '$collection_name'..."
    curl_json DELETE "$postman_api_url/collections/$resource_id" >/dev/null
  fi

  request_body_file="$(make_wrapped_json_file "collection" "$collection_path")"
  echo "Creating collection '$collection_name'..."
  curl_json POST "$postman_api_url/collections$workspace_query" "$request_body_file" >/dev/null
  rm -f "$request_body_file"
done

echo "Collections imported."

if [[ -d "$spec_dir" ]] && compgen -G "$spec_dir/*" >/dev/null; then
  spec_metadata="$(read_spec_metadata)"
  spec_name="$(
    JSON_INPUT="$spec_metadata" ruby -rjson -e '
      data = JSON.parse(ENV.fetch("JSON_INPUT"))
      puts data.fetch("name")
    '
  )"

  existing_specs="$(curl_json GET "$postman_api_url/specs?workspaceId=$workspace_id&limit=100")"
  spec_id="$(
    JSON_INPUT="$existing_specs" TARGET_NAME="$spec_name" ruby -rjson -e '
      data = JSON.parse(ENV.fetch("JSON_INPUT"))
      spec = data.fetch("specs", []).find { |entry| entry["name"] == ENV.fetch("TARGET_NAME") }
      puts(spec ? spec["id"] : "")
    '
  )"

  if [[ -n "$spec_id" ]]; then
    echo "Deleting spec '$spec_name'..."
    curl_json DELETE "$postman_api_url/specs/$spec_id" >/dev/null
  fi

  spec_payload_file="$(make_spec_payload_file "$spec_metadata")"
  echo "Creating spec '$spec_name'..."
  curl_json POST "$postman_api_url/specs?workspaceId=$workspace_id" "$spec_payload_file" >/dev/null
  rm -f "$spec_payload_file"
  echo "Specs imported."
else
  echo "No spec files found. Skipping spec import."
fi

echo "Setup complete."

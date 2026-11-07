#!/usr/bin/env bash

cache_file_path() {
  printf '%s/ipwho/cache.json\n' "${XDG_CACHE_HOME:-$HOME/.cache}"
}

load_cache() {
  jq -cse '
    if length == 1 and
      (.[0] |
        type == "object" and
        .version == 1 and
        (.generated_at | type == "string" and length > 0) and
        (.scope |
          type == "object" and (has("gcp") or has("ovh")) and
          (if has("gcp") then
            (.gcp.projects | type == "array" and length > 0 and all(.[]; type == "string" and length > 0))
           else true end) and
          (if has("ovh") then (.ovh | type == "object" and .dedicated_servers == true)
           else true end)) and
        (.resources |
          type == "object" and all(.[]; type == "array" and all(.[]; type == "object"))))
    then .[0]
    else error("Invalid or unsupported cache format; expected version 1")
    end
  ' "$1"
}

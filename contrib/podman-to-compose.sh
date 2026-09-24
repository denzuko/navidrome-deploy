#!/bin/sh
# podman-to-compose.sh -- dump a running Podman container to a compose file.
#
# usage: podman-to-compose.sh [container] > compose.yaml
#
# Captures image, env (minus what the image already sets), ports, mounts,
# user, restart policy, and capability adds/drops. Env values are written
# verbatim, so treat the output as containing secrets until you've read it.

set -eu

ctr=${1:-navidrome}

command -v podman >/dev/null || { echo "podman not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 1; }
podman container exists "$ctr" || { echo "no container named $ctr" >&2; exit 1; }

inspect=$(podman container inspect "$ctr")
image=$(printf '%s' "$inspect" | jq -r '.[0].ImageName')
image_env=$(podman image inspect "$image" --format '{{json .Config.Env}}' 2>/dev/null || echo '[]')

printf '%s' "$inspect" | jq -r --argjson imgenv "$image_env" '
  def q: tojson;
  .[0] as $c
  | ($c.Name | ltrimstr("/")) as $name
  | ([$c.Config.Env[]
      | select(. as $e | ($imgenv | index($e)) | not)
      | select(test("^(container|HOSTNAME|HOME|TERM)=") | not)]) as $env
  | ([($c.HostConfig.PortBindings // {}) | to_entries[]
      | .key as $cport | .value[]
      | ((if .HostIp == "" or .HostIp == "0.0.0.0" then "" else .HostIp + ":" end)
         + .HostPort + ":" + ($cport | sub("/tcp$"; "")))]) as $ports
  | ([$c.Mounts[]
      | (if .Type == "volume" then .Name else .Source end)
        + ":" + .Destination
        + (if .RW then "" else ":ro" end)]) as $vols
  | ($c.HostConfig.RestartPolicy.Name // "") as $restart
  | "services:",
    "  \($name):",
    "    image: \($c.ImageName | q)",
    "    container_name: \($name | q)",
    (if ($c.Config.User // "") != "" then "    user: \($c.Config.User | q)" else empty end),
    (if $restart != "" and $restart != "no" then "    restart: \($restart | q)" else empty end),
    (if ($ports | length) > 0 then "    ports:", ($ports[] | "      - \(q)") else empty end),
    (if ($env | length) > 0 then "    environment:", ($env[] | "      - \(q)") else empty end),
    (if ($vols | length) > 0 then "    volumes:", ($vols[] | "      - \(q)") else empty end),
    (if ($c.HostConfig.CapAdd // [] | length) > 0
       then "    cap_add:", ($c.HostConfig.CapAdd[] | "      - \(q)") else empty end),
    (if ($c.HostConfig.CapDrop // [] | length) > 0
       then "    cap_drop:", ($c.HostConfig.CapDrop[] | "      - \(q)") else empty end),
    ([$c.Mounts[] | select(.Type == "volume") | .Name] as $named
     | if ($named | length) > 0
       then "volumes:", ($named[] | "  \(.):", "    external: true")
       else empty end)
'

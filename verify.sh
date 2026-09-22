#!/usr/bin/env bash
# Acceptance checks for simple-stock-flow-infra, written before the compose file exists.
# Every check maps to one point of architecture.md section 8.7.
#
# Usage:  ./verify.sh          runs every check and leaves the stack up
#         ./verify.sh --down   tears the stack down when it finishes
#
# This drives the DEVELOPMENT stack: base file plus docker-compose.dev.yml. Two reasons, both
# measured. The direct base the API contract declares in section 1 is http://localhost:5000, and
# the base file alone keeps that port inside the network, so section 6 could not check it at all.
# And bringing the stack up here with the base file alone RECREATES a service container that
# already published the port, silently unpublishing it for whoever else is working.
# Production starts with the base file on its own; the README says so.

set -uo pipefail

PORTAL_PORT="${PORTAL_PORT:-8080}"
SERVICE_PORT="${SERVICE_PORT:-5000}"
DB_SERVICE="db"
# The portal's nginx proxies to this host name, so the service cannot be renamed freely.
API_SERVICE="service"
PORTAL_SERVICE="portal"
DB_NAME="${POSTGRES_DB:-simple_stock_flow}"
DB_USER="${POSTGRES_USER:-simple_stock_flow}"
TEARDOWN="${1:-}"

COMPOSE_FILES=(-f docker-compose.yml -f docker-compose.dev.yml)
compose() { docker compose "${COMPOSE_FILES[@]}" "$@"; }

passed=0
failed=0

pass() { printf '  \033[32mOK\033[0m   %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n'   "$1"; failed=$((failed + 1)); }

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

require_file() {
  local path="$1" description="$2"
  if [ -f "$path" ]; then pass "$description"; else fail "$description — $path is missing"; fi
}

# A query run inside the database container, so the check needs no local client.
query_db() {
  compose exec -T "$DB_SERVICE" psql -U "$DB_USER" -d "$DB_NAME" -tAc "$1" 2>/dev/null
}

section "1. The repository declares its configuration"

require_file ".env.example" "A .env.example exists with the keys the system needs"
require_file "docker-compose.yml" "The docker-compose file exists"
require_file "README.md" "The README exists"

if [ -f ".env.example" ]; then
  missing=""
  for key in POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD JWT_SIGNING_KEY \
             ADMIN_USERNAME ADMIN_PASSWORD PORTAL_PORT; do
    grep -q "^${key}=" .env.example || missing="${missing} ${key}"
  done
  if [ -z "$missing" ]; then
    pass ".env.example declares every mandatory key"
  else
    fail ".env.example does not declare:${missing}"
  fi

  if grep -qE "^(JWT_SIGNING_KEY|ADMIN_PASSWORD|POSTGRES_PASSWORD)=.+" .env.example; then
    fail ".env.example ships a secret with a value — it must declare the key and leave it empty"
  else
    pass ".env.example ships no secret with a value"
  fi
fi

if [ -f ".gitignore" ] && grep -qE "^\.env$" .gitignore; then
  pass ".env is ignored by git"
else
  fail ".env is not ignored by git — a secret would end up versioned"
fi

section "2. The system starts with a single command"

if [ ! -f "docker-compose.yml" ]; then
  fail "There is no docker-compose to start — the remaining checks cannot run"
else
  if compose config >/dev/null 2>&1; then
    pass "The compose definition is valid"
  else
    fail "compose config fails"
  fi

  if compose up -d --wait >/dev/null 2>&1; then
    pass "The three services start and become healthy"
  else
    fail "compose up does not leave the services healthy"
  fi
fi

section "3. The system answers and the schema created itself"

if curl -fsS --max-time 10 "http://localhost:${PORTAL_PORT}/" >/dev/null 2>&1; then
  pass "The portal answers on port ${PORTAL_PORT}"
else
  fail "The portal does not answer on port ${PORTAL_PORT}"
fi

# A protected endpoint answering 401 proves two things at once: the proxy reaches the API and
# the API is guarding its endpoints. The portal does not proxy /health, so this is the path.
api_status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  "http://localhost:${PORTAL_PORT}/api/products" 2>/dev/null)"
if [ "$api_status" = "401" ]; then
  pass "The API answers through the portal and demands a token"
else
  fail "The API does not answer through the portal (status ${api_status:-no answer})"
fi

categories="$(query_db 'select count(*) from sales.category;' | tr -d '[:space:]')"
if [ "${categories:-0}" -ge 5 ] 2>/dev/null; then
  pass "The schema exists and holds the reference categories (${categories})"
else
  fail "No reference categories found: without them not a single product can be created"
fi

section "4. Data survives a restart"

marker="verify-$(date +%s)"
if query_db "insert into sales.category (id, name) values (gen_random_uuid(), '${marker}');" >/dev/null 2>&1; then
  compose restart >/dev/null 2>&1
  sleep 5
  found="$(query_db "select count(*) from sales.category where name = '${marker}';" | tr -d '[:space:]')"
  if [ "${found:-0}" = "1" ]; then
    pass "A row written before the restart is still there afterwards"
    query_db "delete from sales.category where name = '${marker}';" >/dev/null 2>&1
  else
    fail "The restart lost the data — the persistent volume is missing"
  fi
else
  fail "Could not write to the database to check persistence"
fi

section "5. A missing secret is noticed"

# The timeout is part of the check: a host that starts without a signing key never returns,
# and silently accepting an unsigned configuration is the failure this looks for.
# `timeout` execs a binary, so the compose wrapper function is spelled out here on purpose.
without_key="$(timeout 45 docker compose "${COMPOSE_FILES[@]}" \
  run --rm -e Jwt__SigningKey= "$API_SERVICE" 2>&1 | tail -5)"

# The timeout kills the client, not the container it started: clean it up or it lingers.
docker ps -aq --filter "name=-${API_SERVICE}-run-" | xargs -r docker rm -f >/dev/null 2>&1

if echo "$without_key" | grep -qiE "signingkey|jwt"; then
  pass "With no signing key, the API fails and says why"
else
  fail "With no signing key, the API does not fail with an explicit error (article IX)"
fi

section "6. What is deployed is what the source says"

# `up -d --wait` adopts whatever image already carries the tag and never rebuilds, so an image
# built before the last change to the portal source keeps serving an old bundle while every other
# check in this file still passes. That is how a fix for the report date range, the interceptor
# that names the field of a 400 and the guard for a null currency stayed undeployed for two hours
# with the suite green. Building here costs a cached docker build; not building costs the truth.
#
# The comparison is by content, never by image id: a cached rebuild still mints a fresh id —
# the config blob carries its own timestamp — so equal ids would never be a reachable state.
#
# Paths travel inside `sh -c` because MSYS, the shell that ships with Git for Windows, rewrites
# an argument that looks like an absolute path into a Windows one before docker ever sees it.
hash_in_image() { docker run --rm --entrypoint sh "$1" -c "sha256sum $2" 2>/dev/null | cut -d' ' -f1; }
hash_in_container() { docker exec "$1" sh -c "sha256sum $2" 2>/dev/null | cut -d' ' -f1; }

portal_cid="$(compose ps -q "$PORTAL_SERVICE" 2>/dev/null)"
build_log="$(mktemp)"
compose build "$PORTAL_SERVICE" >"$build_log" 2>&1
build_status=$?
if [ "$build_status" -ne 0 ]; then
  fail "The portal image does not build — see ${build_log}"
elif [ -z "$portal_cid" ]; then
  rm -f "$build_log"
  fail "There is no portal container running to compare against the source"
else
  rm -f "$build_log"
  fresh_image="$(docker inspect "$portal_cid" -f '{{.Config.Image}}' 2>/dev/null)"

  # index.html names every hashed bundle, so one changed TypeScript file changes this hash.
  # Read over HTTP on purpose: this is the byte stream a browser gets, not a claim about a tag.
  served_index="$(curl -fsS --max-time 10 "http://localhost:${PORTAL_PORT}/index.html" 2>/dev/null \
    | sha256sum | cut -d' ' -f1)"
  fresh_index="$(hash_in_image "$fresh_image" /usr/share/nginx/html/index.html)"
  if [ -n "$fresh_index" ] && [ "$served_index" = "$fresh_index" ]; then
    pass "The bundle served on port ${PORTAL_PORT} is the bundle the source compiles to"
  else
    fail "The portal serves a stale bundle — rebuild the image and bring the stack up again"
  fi

  # The bundle hash says nothing about the proxy: a change to nginx.conf alone leaves index.html
  # untouched, and the media and upload checks below would then be measuring an old container.
  live_conf="$(hash_in_container "$portal_cid" /etc/nginx/conf.d/default.conf)"
  fresh_conf="$(hash_in_image "$fresh_image" /etc/nginx/conf.d/default.conf)"
  if [ -n "$fresh_conf" ] && [ "$live_conf" = "$fresh_conf" ]; then
    pass "The nginx configuration running is the one the portal source declares"
  else
    fail "The portal runs a stale nginx.conf — rebuild the image and bring the stack up again"
  fi
fi

# nginx gives regular expressions precedence over prefixes, so the static-asset block swallowed
# /media/*.jpg and /media/*.png and answered them with its own 153-byte HTML page: of the three
# content types the API accepts, only webp ever reached the browser (defect A-6, CA-03.1).
# The service answers an unknown key with an empty 404, and that emptiness is the evidence.
ABSENT_KEY="00000000000000000000000000000000"
ABSENT_PRODUCT="00000000-0000-4000-8000-000000000000"
for extension in jpg png webp; do
  read -r media_status media_length <<<"$(curl -s -o /dev/null -w '%{http_code} %{size_download}' \
    --max-time 10 "http://localhost:${PORTAL_PORT}/media/${ABSENT_KEY}.${extension}" 2>/dev/null)"
  if [ "$media_status" = "404" ] && [ "${media_length:-0}" = "0" ]; then
    pass "/media/*.${extension} is proxied to the API, not answered by nginx"
  else
    fail "/media/*.${extension} does not reach the API (status ${media_status:-no answer}, ${media_length:-0} bytes)"
  fi
done

# Without client_max_body_size nginx caps the body at 1 MB, so an ordinary phone photo got a
# 413 in HTML and the 422 the contract decided for 5 MB (E-08) was unreachable through the portal.
# No token is needed to prove the body crossed nginx: the 401 can only come from the API.
# The -F value carries no `;type=` or `;filename=`: MSYS reads a semicolon-separated list as a
# path list and rewrites it, and curl then cannot open the file at all.
payload="$(mktemp)"
head -c 2000000 /dev/zero >"$payload" 2>/dev/null
upload_status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X POST \
  -F "file=@${payload}" \
  "http://localhost:${PORTAL_PORT}/api/products/${ABSENT_PRODUCT}/image" 2>/dev/null)"
rm -f "$payload"
if [ "$upload_status" = "401" ]; then
  pass "A 2 MB upload crosses nginx and is the API's to judge"
else
  fail "A 2 MB upload does not reach the API (status ${upload_status:-no answer}; 413 means nginx cut it)"
fi

# api-contract.md section 1 declares http://localhost:5000 a valid base in development, and the
# proxy of `ng serve` forwards there. Published only by the development overlay.
direct_status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  "http://localhost:${SERVICE_PORT}/health" 2>/dev/null)"
if [ "$direct_status" = "200" ]; then
  pass "The API answers on its own port ${SERVICE_PORT}, the direct base of the contract"
else
  fail "The API does not answer on port ${SERVICE_PORT} (status ${direct_status:-no answer})"
fi

# Everything above this line reaches the service DIRECTLY. That is exactly how a proxy defect
# stays green: the script never walks the road the person walks. These checks go through the
# portal on purpose, because A-9 and A-11 both break the trip and neither breaks the service.
section "6b. The road through the portal is the road the person walks"

# A-11. /api/ as a bare prefix loses to the static-asset regular expression, so any API path that
# happens to end in .jpg/.css/.png is answered by nginx's own 404 page instead of reaching the API.
# The proof is the SIZE, exactly as it was when A-6 was found: nginx's page is 153 bytes of HTML,
# the API's 404 is empty. No token needed -- an unauthenticated 401/404 travels the same road.
api_ext_bytes="$(curl -s -o /dev/null -w '%{size_download}' "http://localhost:${PORTAL_PORT}/api/loquesea.jpg" 2>/dev/null)"
api_ext_type="$(curl -s -o /dev/null -w '%{content_type}' "http://localhost:${PORTAL_PORT}/api/loquesea.jpg" 2>/dev/null)"
if [ "${api_ext_bytes:-1}" = "0" ]; then
  pass "An API path ending in .jpg reaches the API (0 bytes back, not nginx's page)"
else
  fail "http://localhost:${PORTAL_PORT}/api/loquesea.jpg came back as ${api_ext_bytes} bytes of ${api_ext_type:-?} — nginx answered it, the API never saw it"
fi

# A-9. $host drops the port; $http_host keeps it. A 201's Location is where this shows, and reading
# one would mean creating a product through the portal and leaving the row behind on every run, so
# this asserts the configuration and the behaviour is measured by hand. The count is printed rather
# than a bare verdict: "0 blocks use $host" and "there are no blocks at all" look identical otherwise.
conf="../simple-stock-flow-portal/nginx.conf"
if [ ! -f "$conf" ]; then
  fail "The portal nginx.conf is not where this check expects it (${conf})"
else
  # Anchored to the start of the line: a COMMENT that merely mentions proxy_pass counted as a
  # block and made this check fail with "0 of 4" against three real blocks. It failed loudly,
  # which is the only reason it was caught -- the same mistake in the other direction reads green.
  host_uses="$(grep -cE '^[[:space:]]*proxy_set_header Host \$host;' "$conf")"
  httphost_uses="$(grep -cE '^[[:space:]]*proxy_set_header Host \$http_host;' "$conf")"
  proxy_blocks="$(grep -cE '^[[:space:]]*proxy_pass ' "$conf")"
  if [ "$host_uses" = "0" ] && [ "$httphost_uses" = "$proxy_blocks" ]; then
    pass "All ${proxy_blocks} proxied blocks forward Host with the port (\$http_host), none drops it"
  else
    fail "${host_uses} of ${proxy_blocks} proxied blocks still use \$host, which drops the port from Location (A-9)"
  fi

  # A-11 again, at the source: a prefix that does not win outright is one static-asset extension
  # away from the defect coming back, and the behavioural check above only catches the extensions
  # the regular expression happens to list today.
  weak="$(grep -nE '^\s*location\s+/(api|media)/' "$conf" | tr -d ' ' | tr '\n' ' ')"
  if [ -z "$weak" ]; then
    pass "/api/ and /media/ are declared ^~, so no regular expression can outrank them"
  else
    fail "A proxied prefix is declared without ^~ and a regex can steal it: ${weak}"
  fi
fi

# T-14, RNF-05. Two separate promises: a failed request can be followed end to end by its
# correlation, and nothing that identifies a person or unlocks an account is written down. The
# second one is why this runs against the real log stream and not against the configuration: what
# a logger is told to redact and what it actually writes are different claims.
# H-6 and gap H-2 of the data model. /media/{key} is anonymous by decision -- an <img> tag cannot
# send an Authorization header -- so every binary in that volume is world-readable for as long as
# it exists, and a leaked URL never expires. Seven binaries were found belonging to no product at
# all: probe uploads and images of products taken down. Nothing in the system ever deletes them,
# so the pile only grows, and each one is public forever. This counts them out loud.
section "6d. The image volume holds nothing that belongs to nobody"

media_root="/var/lib/simple-stock-flow/media"
served="$(compose exec -T "$API_SERVICE" sh -c "ls -1 ${media_root} 2>/dev/null | grep -v '^cuarentena' | wc -l" </dev/null 2>/dev/null | tr -d '[:space:]')"
quarantined="$(compose exec -T "$API_SERVICE" sh -c "ls -1 ${media_root}/cuarentena-* 2>/dev/null | wc -l" </dev/null 2>/dev/null | tr -d '[:space:]')"
referenced="$(query_db "SELECT count(*) FROM sales.product WHERE image_key IS NOT NULL;")"

if [ -z "$served" ] || [ -z "$referenced" ]; then
  fail "The image volume or the catalogue could not be read, so orphans cannot be counted"
elif [ "$served" = "0" ] && [ "$referenced" = "0" ]; then
  pass "No product carries an image yet and the volume is empty: nothing to orphan"
elif [ "$served" = "$referenced" ]; then
  # Both numbers printed on purpose. "0 orphans" out of 29 files and "0 orphans" out of 0 files
  # read identically as a verdict, and only one of them means the volume is clean.
  pass "All ${served} served binaries belong to a product (${referenced} referenced, ${quarantined:-0} in quarantine)"
else
  fail "${served} binaries are served but only ${referenced} are referenced: $((served - referenced)) belong to nobody and are public forever (H-6)"
fi

section "6c. The logs can be followed, and give nothing away"

log_probe_password="sonda-t14-no-es-una-clave-real"
curl -s -o /dev/null --max-time 10 -X POST "http://localhost:${SERVICE_PORT}/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"${log_probe_password}\"}" 2>/dev/null

service_logs="$(compose logs --tail 200 "$API_SERVICE" 2>/dev/null)"

if [ -z "$service_logs" ]; then
  fail "The service wrote no log lines to read, so neither promise can be checked"
else
  # Counted, not just judged: "no request lines at all" and "every request line carries it" are
  # the same verdict otherwise, and the first one would be a silent hole.
  request_lines="$(echo "$service_logs" | grep -c 'HTTP {RequestMethod}')"
  correlated="$(echo "$service_logs" | grep 'HTTP {RequestMethod}' | grep -c '"@tr":')"
  if [ "${request_lines:-0}" -eq 0 ]; then
    fail "No request was logged at all, so there is nothing to correlate"
  elif [ "$request_lines" = "$correlated" ]; then
    pass "All ${request_lines} request log lines carry a correlation id (@tr)"
  else
    fail "${correlated} of ${request_lines} request log lines carry a correlation id"
  fi

  leaked=""
  echo "$service_logs" | grep -qF "$log_probe_password" && leaked="${leaked} the-password-as-sent"
  echo "$service_logs" | grep -q 'pbkdf2' && leaked="${leaked} a-password-hash"
  echo "$service_logs" | grep -qE 'eyJ[A-Za-z0-9_-]{10,}' && leaked="${leaked} a-bearer-token"
  if [ -z "$leaked" ]; then
    pass "The logs carry no password, no hash and no token across ${request_lines} requests"
  else
    fail "The logs give away:${leaked}"
  fi
fi

section "7. The API documents itself, and the documentation is reachable"

# The mount used to hang off IsDevelopment() while the container runs as Production, so the page
# was missing from the only deployment anyone reads it in and /swagger answered 404. These checks
# exist so that cannot come back quietly.
swagger_direct="http://localhost:${SERVICE_PORT}/swagger"
swagger_portal="http://localhost:${PORTAL_PORT}/swagger"

# /swagger without the file name must redirect, and the redirect must keep the port. Swashbuckle
# answers it with a relative Location for exactly this reason; a proxy that rewrote it to an
# absolute one without the port would send the browser to port 80.
redirect_target="$(curl -s -o /dev/null -w '%{redirect_url}' --max-time 10 "${swagger_portal}" 2>/dev/null)"
if [ "$redirect_target" = "http://localhost:${PORTAL_PORT}/swagger/index.html" ]; then
  pass "/swagger redirects to its index through the portal without losing the port"
else
  fail "/swagger redirects to '${redirect_target:-nothing}' through the portal"
fi

# The page is served by the API, so the bytes have to be the API's. Comparing them against the
# direct base is what tells a proxied page apart from the SPA's index.html, which also answers
# 200 and would otherwise look like success: before `location ^~ /swagger` existed, the portal
# returned the Angular shell here and nothing about the status code said so.
direct_page="$(curl -fsS --max-time 10 "${swagger_direct}/index.html" 2>/dev/null | sha256sum | cut -d' ' -f1)"
portal_page="$(curl -fsS --max-time 10 "${swagger_portal}/index.html" 2>/dev/null | sha256sum | cut -d' ' -f1)"
if [ -n "$direct_page" ] && [ "$direct_page" = "$portal_page" ]; then
  pass "The Swagger page answers identically on port ${SERVICE_PORT} and through the portal"
elif [ -z "$direct_page" ]; then
  fail "The Swagger page does not answer on port ${SERVICE_PORT} — Swagger:Enabled or the mount"
else
  fail "The portal answers /swagger/index.html with something else — the SPA fallback swallowed it"
fi

# nginx tries regular expressions before prefixes, and the static-asset block matches .css and
# .js: without `^~` winning, these two are answered by the portal's own 404 page and the page
# arrives unstyled and without its script. This is defect A-6 in a second costume.
for asset in swagger-ui.css swagger-ui-bundle.js; do
  direct_asset="$(curl -fsS --max-time 20 "${swagger_direct}/${asset}" 2>/dev/null | sha256sum | cut -d' ' -f1)"
  portal_asset="$(curl -fsS --max-time 20 "${swagger_portal}/${asset}" 2>/dev/null | sha256sum | cut -d' ' -f1)"
  if [ -n "$direct_asset" ] && [ "$direct_asset" = "$portal_asset" ]; then
    pass "/swagger/${asset} reaches the API through the portal, not nginx's own tree"
  else
    fail "/swagger/${asset} is not the API's through the portal — the static-asset rule took it"
  fi
done

document="$(curl -fsS --max-time 10 "${swagger_direct}/v1/swagger.json" 2>/dev/null)"
if [ -n "$document" ]; then
  pass "The OpenAPI document answers on ${swagger_direct}/v1/swagger.json"
else
  fail "The OpenAPI document does not answer"
fi

# One route per endpoint sheet of api-contract.md section 4: E-01 and E-02, E-03 to E-08, E-09,
# E-10 to E-12, E-13, E-14 and E-15. A document that lists fewer of them is not the contract's.
missing_routes=""
for route in "/api/auth/login" "/api/auth/register" "/api/products" "/api/products/{id}" \
             "/api/products/{id}/image" "/api/categories" "/api/sales" "/api/sales/{id}" \
             "/api/reports/sales" "/health" "/media/{key}"; do
  echo "$document" | grep -qF "\"${route}\":" || missing_routes="${missing_routes} ${route}"
done
if [ -z "$missing_routes" ]; then
  pass "The OpenAPI document declares every route the contract promises"
else
  fail "The OpenAPI document does not declare:${missing_routes}"
fi

# Listing the routes is not documenting them. Every operation carries a summary, and the count is
# what stops a silent regression: turning GenerateDocumentationFile off again leaves the page
# standing and empties it, and no other check here would notice.
summaries="$(echo "$document" | grep -o '"summary":' | wc -l | tr -d '[:space:]')"
if [ "${summaries:-0}" -ge 15 ] 2>/dev/null; then
  pass "Every operation carries a description (${summaries} summaries)"
else
  fail "Only ${summaries:-0} operations are described — the XML documentation file is not being read"
fi

# The Authorize button is the difference between a page you read and a page you can use.
if echo "$document" | grep -q '"bearerFormat"'; then
  pass "The document declares the bearer scheme, so the page can send a token"
else
  fail "The document declares no bearer scheme — Authorize would have nothing to fill in"
fi

# The three anonymous endpoints -- login, health and the media route -- must not claim to need a
# token: whoever reads that signing in needs one has nowhere left to start. Declaring the bearer
# once for the whole document is the easy way to get this wrong, and it is countable: blanket
# leaves a single "security", per operation leaves one for each of the twelve guarded ones.
guarded="$(echo "$document" | grep -o '"security":' | wc -l | tr -d '[:space:]')"
if [ "${guarded:-0}" -ge 12 ] 2>/dev/null; then
  pass "The bearer requirement is per operation (${guarded}), so the anonymous ones read as anonymous"
else
  fail "Only ${guarded:-0} security requirements — a blanket one padlocks login, health and media"
fi

# T-11 closed the last gap the signed contract had, and a gap that closes silently reopens the same
# way. E-13 declares categoryName a non-null string WITH A MEANING, and an empty one satisfies the
# type while breaking the promise -- which is exactly how it went unnoticed before.
#
# Measured at the source rather than through the API, because this script holds no credentials by
# design and the report projects the column straight through: a line with a label is a row with one.
# A-10. The document is what a client is generated FROM, so a lie here compiles into somebody
# else's code. Two of them shipped: from/to were declared optional although the API answers 400
# without them, and every string was declared nullable although the contract says otherwise --
# including currency, which D-C10 protects by name because a null there breaks the report screen.
# Python does the reading: these are nested structures and grep would be guessing.
if [ -n "${document:-}" ]; then
  openapi_report="$(printf '%s' "$document" | python -c '
import json, sys
doc = json.load(sys.stdin)

optional = []
for path, methods in doc.get("paths", {}).items():
    for method, operation in methods.items():
        for parameter in operation.get("parameters", []):
            if parameter.get("name") in ("from", "to") and not parameter.get("required"):
                optional.append(path + " " + parameter["name"])

schemas = doc.get("components", {}).get("schemas", {})

# Nullable is not a defect by itself -- it is a defect when it contradicts the contract. The first
# version of this check flagged all 31 strings and stayed red at 9 that are nullable on purpose:
# the framework problem bodies, whose title/detail/instance are absent by design, and imageUrl,
# which the contract declares nullable because a product may have no image. Naming the exemptions
# rather than loosening the rule keeps the check honest: a NEW nullable string still fails.
ALLOWED_NULLABLE = {"ProductView.imageUrl"}
FRAMEWORK_SCHEMAS = {"ProblemDetails", "ValidationProblemDetails", "HttpValidationProblemDetails"}

nullable, without_required = [], []
for name, schema in schemas.items():
    if name in FRAMEWORK_SCHEMAS:
        continue
    for field, spec in (schema.get("properties") or {}).items():
        if spec.get("nullable") and spec.get("type") == "string" and name + "." + field not in ALLOWED_NULLABLE:
            nullable.append(name + "." + field)
    if (schema.get("properties") or {}) and not schema.get("required"):
        without_required.append(name)

print(len(optional), len(nullable), len(without_required))
print(" ".join(optional[:4]))
print(" ".join(nullable[:4]))
print(" ".join(without_required[:4]))
' 2>/dev/null)"
  openapi_counts="$(echo "$openapi_report" | sed -n 1p)"
  optional_dates="$(echo "$openapi_counts" | cut -d' ' -f1)"
  nullable_strings="$(echo "$openapi_counts" | cut -d' ' -f2)"
  schemas_loose="$(echo "$openapi_counts" | cut -d' ' -f3)"

  if [ "${optional_dates:-x}" = "0" ]; then
    pass "Every from/to parameter in the document is declared required, as the API enforces"
  else
    fail "${optional_dates} date parameters are declared optional although the API answers 400 without them: $(echo "$openapi_report" | sed -n 2p)"
  fi

  if [ "${nullable_strings:-x}" = "0" ]; then
    pass "No string property is declared nullable, matching what the contract promises"
  else
    fail "${nullable_strings} string properties are declared nullable: $(echo "$openapi_report" | sed -n 3p)"
  fi

  if [ "${schemas_loose:-x}" = "0" ]; then
    pass "Every schema with properties declares which of them are required"
  else
    fail "${schemas_loose} schemas declare no required list, so a generator makes every field optional: $(echo "$openapi_report" | sed -n 4p)"
  fi
else
  fail "The OpenAPI document was not read, so its declarations cannot be checked"
fi

section "7b. Every sale line carries the category it froze"

blank_labels="$(query_db "SELECT count(*) FROM sales.sale_item WHERE category_name IS NULL OR btrim(category_name) = '';")"
all_lines="$(query_db "SELECT count(*) FROM sales.sale_item;")"

if [ -z "$all_lines" ]; then
  fail "The sale lines could not be counted, so the frozen category cannot be checked"
elif [ "$all_lines" = "0" ]; then
  pass "There are no sale lines yet, and an empty system is not a failure"
elif [ "$blank_labels" = "0" ]; then
  pass "All ${all_lines} sale lines carry a frozen category (E-13, T-11)"
else
  fail "${blank_labels} of ${all_lines} sale lines have no frozen category — E-13 promises one on every row"
fi

# The column must refuse the blank rather than trust everyone to fill it, and it must carry no
# default: a default would let a future writer forget the label and never be told.
category_column="$(query_db "SELECT is_nullable || '/' || coalesce(column_default, 'sin-defecto') FROM information_schema.columns WHERE table_schema = 'sales' AND table_name = 'sale_item' AND column_name = 'category_name';")"
if [ "$category_column" = "NO/sin-defecto" ]; then
  pass "sale_item.category_name is NOT NULL and has no default, so a forgotten label fails loudly"
else
  fail "sale_item.category_name reads '${category_column:-absent}', expected 'NO/sin-defecto'"
fi

section "8. The documents do not publish numbers that rot"

# Why this section exists at all. HANDOFF.md section 4 once declared a fifth of the tests that
# existed and half the checks this script runs, and nobody noticed for days -- not through
# carelessness, but because a figure written in prose has nobody watching it. The rule the project
# now follows is that the state section names the COMMAND that produces a number instead of the
# number itself. A rule with no check is a wish, so these checks are the teeth.
DOCS="../simple-stock-flow-docs"
HANDOFF="${DOCS}/traspaso/HANDOFF.md"
TECH="${DOCS}/traspaso/HANDOFF-TECNICO.md"
TASKS="${DOCS}/spec/tasks.md"

if [ -f "$HANDOFF" ]; then
  state="$(awk '/^## 4\./{on=1} /^## 5\./{on=0} on' "$HANDOFF")"

  # A reader who cannot run anything still has to be able to find out how. Naming the commands is
  # the whole point of the section: without them it is an empty promise instead of a redirection.
  missing=""
  for command in "dotnet build SimpleStockFlow.sln" "dotnet test SimpleStockFlow.sln" "ng test" "./verify.sh"; do
    echo "$state" | grep -qF "$command" || missing="${missing} '${command}'"
  done
  if [ -z "$missing" ]; then
    pass "The state section names the commands that produce the state"
  else
    fail "The state section does not name:${missing}"
  fi

  # A count that GROWS with the work is what rots; an invariant is not a count. "0 failed" and
  # "0 warnings" may be written here forever, because the day they stop being true is exactly the
  # day we want to hear about it. What may not be written is how many of anything there are.
  rotten="$(echo "$state" | grep -nE '[0-9]+ *(/|de) *[0-9]+|[0-9]+ *%|[0-9]+ (tests|pruebas|comprobaciones|proyectos|tareas)' || true)"
  if [ -z "$rotten" ]; then
    pass "The state section publishes no count that grows with the work"
  else
    fail "The state section has a count pasted back into it: ${rotten}"
  fi
else
  fail "HANDOFF.md is missing — the state section cannot be checked"
fi

# The one number that IS written down, because somebody reads the progress without a terminal.
# It is allowed precisely because this check recomputes it from the table underneath it.
if [ -f "$TASKS" ]; then
  done_rows="$(grep -c '^| \*\*T-.*✅' "$TASKS" || true)"
  all_rows="$(grep -c '^| \*\*T-' "$TASKS" || true)"
  declared="$(grep -oE '\*\*[0-9]+ de [0-9]+ hechas' "$TASKS" | head -1 | grep -oE '[0-9]+ de [0-9]+' || true)"
  if [ -z "$declared" ]; then
    fail "tasks.md declares no progress count for this check to contrast"
  elif [ "$declared" = "${done_rows} de ${all_rows}" ]; then
    pass "The progress tasks.md declares (${declared}) is what its own table says"
  else
    fail "tasks.md declares '${declared}' and its table says '${done_rows} de ${all_rows}'"
  fi
else
  fail "spec/tasks.md is missing — the progress count cannot be contrasted"
fi

# An open defect with no probe beside it cannot be closed by anyone but its author: "fixed" stays
# an opinion. Writing the probe BEFORE the fix is what makes closure a measurement.
if [ -f "$TECH" ]; then
  open_defects="$(awk '/^### 6\.1/{on=1} /^### 6\.2/{on=0} on && /^\| \*\*A-/' "$TECH")"
  total_defects="$(echo "$open_defects" | grep -c '^| \*\*A-' || true)"
  # Five columns means the probe column is filled; four means somebody added a row without one.
  without="$(echo "$open_defects" | awk -F'|' 'gsub(/\\|/,"",$0) || 1 {n=split($0,c,"|"); if (n-2 < 5) print $2}')"
  # An empty table is a legitimate state -- it means every defect the inventory ever held is
  # closed -- and this check used to read it as a failure, because it was written assuming there
  # would always be at least one row. Saying "0 open defects" out loud is the point: an empty set
  # and an invariant read identically as a bare verdict, and only one of them is good news.
  if [ "${total_defects:-0}" -eq 0 ]; then
    pass "0 open defects on record: the inventory is empty, not unchecked"
  elif [ -z "$without" ]; then
    pass "Every open defect (${total_defects}) carries the probe that would close it"
  else
    fail "Open defects with no closing probe: ${without}"
  fi
else
  fail "HANDOFF-TECNICO.md is missing — the defect inventory cannot be checked"
fi

section "9. The signed documents declare their debt instead of hiding it"

# api-contract.md and data-model.md are SIGNED: no agent rewrites them, and several of their
# statements stopped being true as the system was fixed. A check that failed once per stale
# statement would fail every day until the owner decides, and a check that always fails is a check
# people learn to ignore. So this does not check whether the statements are TRUE -- it checks that
# every one known to be false is DECLARED, in a register, where a reader meets it.
# A declared lie is debt. A silent lie is a trap.
CONTRACT="${DOCS:-../simple-stock-flow-docs}/spec/api-contract.md"
MODEL="${DOCS:-../simple-stock-flow-docs}/spec/data-model.md"

check_debt_register() {
  local document="$1" prefix="$2" title="$3"

  if [ ! -f "$document" ]; then
    fail "${title} is missing -- its debt register cannot be checked"
    return
  fi

  if ! grep -q "Registro de deuda declarada" "$document"; then
    fail "${title} has no debt register, so anything stale in it is stale in silence"
    return
  fi

  # The register is only as good as its date: it says when somebody last measured, and a register
  # nobody has re-measured is itself a stale claim.
  if grep -qE "Medido el [0-9]{4}-[0-9]{2}-[0-9]{2}" "$document"; then
    pass "${title} dates when its debt was last measured against the system"
  else
    fail "${title} has a debt register with no measurement date"
  fi

  # Written without backslashes on purpose: awk silently drops \| and \* from a dynamic regex, and
  # the pattern then matches nearly every table in the document. Strip the cell and compare it whole.
  local rows open_rows marks thin
  rows="$(awk -F'|' -v pre="$prefix" '
    { key = $2; gsub(/[ \t*~]/, "", key)
      if (key ~ ("^" pre "-[0-9]+$")) print key }' "$document" | sort -u)"
  open_rows="$(awk -F'|' -v pre="$prefix" '
    { key = $2; gsub(/[ \t*~]/, "", key)
      if (key ~ ("^" pre "-[0-9]+$") && $3 ~ /Abierta/) print key }' "$document" | sort -u)"
  marks="$(grep -oE "Deuda declarada ${prefix}-[0-9]+" "$document" | grep -oE "${prefix}-[0-9]+" | sort -u)"

  if [ -z "$rows" ]; then
    fail "${title} declares no debt entry at all"
    return
  fi

  # The split is the whole point, and it is what keeps this from failing every day. An OPEN debt must
  # carry its warning where the reader meets the false sentence; a SETTLED one must NOT, because the
  # sentence was corrected and a leftover warning would send the reader chasing nothing. Paying the
  # debt therefore keeps the register green instead of emptying it -- an entry stays as history.
  if [ "$marks" = "$open_rows" ]; then
    local total settled
    total="$(echo "$rows" | wc -l | tr -d '[:space:]')"
    settled=$((total - $(echo "$open_rows" | grep -c . )))
    pass "${title}: ${total} debts on record, $(echo "$open_rows" | grep -c .) still open and marked, ${settled} settled and unmarked"
  else
    fail "${title}: an open debt with no mark, or a settled one still marked: $(comm -3 <(echo "$marks") <(echo "$open_rows") | tr -d '\t' | tr '\n' ' ')"
  fi

  # An entry missing a cell throws the point away: it would say "something here is wrong" without
  # saying what is true instead, which is worse than saying nothing at all.
  thin="$(awk -F'|' -v pre="$prefix" '
    {
      key = $2
      gsub(/[ \t*~]/, "", key)
      if (key ~ ("^" pre "-[0-9]+$")) {
        empty = 0
        for (i = 3; i <= NF - 1; i++) { cell = $i; gsub(/^[ \t]+|[ \t]+$/, "", cell); if (cell == "") empty = 1 }
        if (NF - 2 < 5 || empty) { print key }
      }
    }' "$document" | tr '\n' ' ')"
  if [ -z "$thin" ]; then
    pass "${title}: every debt says what the document claimed AND what reality measured"
  else
    fail "${title}: incomplete debt entries: ${thin}"
  fi
}

check_debt_register "$CONTRACT" "O" "api-contract.md"
check_debt_register "$MODEL" "D" "data-model.md"

if [ "$TEARDOWN" = "--down" ]; then
  compose down >/dev/null 2>&1
fi

printf '\n\033[1mResult: %d passed, %d failed\033[0m\n' "$passed" "$failed"
[ "$failed" -eq 0 ]

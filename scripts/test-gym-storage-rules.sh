#!/usr/bin/env bash
# Photo upload rules, over real HTTP through the LOCAL Supabase stack (never a cloud project). The rules live in a
# trigger on storage.objects (20261030000003), because the policy only runs when an upload token is issued and the
# upload itself runs with no session. Each attack below used to work; every one must now fail.
# Needs `scripts/supabase-up.sh` to have run (it writes supabase/.env.local).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/supabase/.env.local"
DB_CONTAINER="supabase_db_gymrollins"

[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE — run scripts/supabase-up.sh first" >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
[[ "$API_URL" =~ ^http://(127\.0\.0\.1|localhost):[0-9]+/?$ ]] || {
  echo "Refusing to run: API_URL ($API_URL) is not a local stack" >&2; exit 1; }
API_URL="${API_URL%/}"
ST="$API_URL/storage/v1"
PASSWORD="GymStorageRules-1-local"
WORK="$(mktemp -d -t gym-storage-rules)"
FAILS=0

psql_local() { docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -tA "$@"; }
uuid() { python3 -I -c 'import uuid;print(uuid.uuid4())'; }
json_get() { python3 -I -c 'import json,sys;d=json.load(sys.stdin)
for k in sys.argv[1].split("."): d=d[k]
print(d)' "$1"; }
check() { # description, command that succeeds when the rule held
  local what="$1"; shift
  if "$@"; then echo "  ok    $what"; else echo "  FAIL  $what" >&2; FAILS=$((FAILS + 1)); fi
}

objects_of() { psql_local -c "select count(*) from storage.objects where owner_id = '$1'
  and bucket_id in ('gym-photos', 'gym-photos-private')" </dev/null; }

# Storage objects can only be deleted through the API (or with the setting below), so the files go too.
cleanup() {
  psql_local -c "
    delete from public.gym_equipment where gym_id in (select id from public.gyms where maps_place_id like 'e2e-storage-%');
    delete from public.gyms where maps_place_id like 'e2e-storage-%';
    begin;
    set local storage.allow_delete_query = 'true';
    delete from storage.objects where bucket_id in ('gym-photos', 'gym-photos-private')
      and owner_id in (select id::text from auth.users where email like 'gym-storage-%@test.local');
    commit;
    delete from auth.users where email like 'gym-storage-%@test.local'" >/dev/null
}
cleanup
trap 'cleanup || true; rm -r "$WORK"' EXIT

new_user() { # prints "<access token> <user id>"
  local out
  out=$(curl -s "$API_URL/auth/v1/signup" -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' \
    -d "{\"email\":\"gym-storage-$1-$(uuid)@test.local\",\"password\":\"$PASSWORD\"}")
  python3 -I -c 'import json,sys;d=json.loads(sys.argv[1]);print(d["access_token"], d["user"]["id"])' "$out"
}
rpc() { # token, function, json body
  curl -s -w '\n%{http_code}' "$API_URL/rest/v1/rpc/$2" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $1" \
    -H 'Content-Type: application/json' -d "$3"
}
sign() { # token, bucket, name [extra header]; prints the upload token
  curl -s -X POST "$ST/object/upload/sign/$2/$3" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $1" \
    -H 'Content-Type: application/json' ${4:+-H "$4"} -d '{}' | json_get token
}
put_token() { # bucket, name, upload token, file [extra header]; prints the HTTP status
  curl -s -o /dev/null -w '%{http_code}' -X PUT "$ST/object/upload/sign/$1/$2?token=$3" -H "apikey: $ANON_KEY" \
    -H 'Content-Type: image/jpeg' ${5:+-H "$5"} --data-binary "@$4"
}
post_object() { # token, bucket, name, file [content type]; prints the HTTP status
  curl -s -o /dev/null -w '%{http_code}' -X POST "$ST/object/$2/$3" -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $1" -H "Content-Type: ${5:-image/jpeg}" --data-binary "@$4"
}
public_bytes() { curl -s "$ST/object/public/gym-photos/$1"; }
public_type() { curl -s -D - -o /dev/null "$ST/object/public/gym-photos/$1" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-type"{print $2}'; }

printf '\xff\xd8\xff\xe0BENIGN-JPEG-BYTES' > "$WORK/benign.jpg"
printf '\xff\xd8\xff\xe0SWAPPED-BYTES-BY-ATTACKER' > "$WORK/evil.jpg"
printf '\xff\xd8\xff\xe0x' > "$WORK/tiny.jpg"

read -r TOKEN_A ID_A <<<"$(new_user a)"
read -r TOKEN_B ID_B <<<"$(new_user b)"

share() { # token, gym id, kind, photo name; prints the HTTP status
  local out
  out=$(rpc "$1" share_listing "{\"p_listing_id\":\"$(uuid)\",\"p_gym_id\":\"$2\",\"p_kind_id\":\"$3\",\"p_brand\":null,
    \"p_model\":null,\"p_loads\":{\"type\":\"none\"},\"p_quantity\":1,\"p_notes\":null,\"p_photo_path\":\"$4\",
    \"p_force_new\":true}")
  echo "${out##*$'\n'}"
}
out=$(rpc "$TOKEN_A" find_or_create_gym "{\"p_maps_place_id\":\"e2e-storage-$(uuid)\",\"p_name\":\"Storage Rules Gym\",
  \"p_address\":null,\"p_latitude\":null,\"p_longitude\":null}")
GYM=$(echo "${out%$'\n'*}" | tr -d '"')
[[ "$GYM" =~ ^[0-9a-f-]{36}$ ]] || { echo "Could not create the test gym: $out" >&2; exit 1; }

echo "A normal upload still works"
NORMAL="$(uuid).jpg"
check "upload a JPEG" test "$(post_object "$TOKEN_A" gym-photos "$NORMAL" "$WORK/benign.jpg")" = 200
check "share a listing with it" test "$(share "$TOKEN_A" "$GYM" flat-bench "$NORMAL")" = 200
check "the public URL serves those bytes" test "$(public_bytes "$NORMAL")" = "$(cat "$WORK/benign.jpg")"
check "served as image/jpeg" test "$(public_type "$NORMAL")" = image/jpeg
PRIVATE_NAME="$(uuid).jpg"
check "a private-bucket upload works" test "$(post_object "$TOKEN_A" gym-photos-private "$PRIVATE_NAME" "$WORK/benign.jpg")" = 200

echo "A token with x-upsert cannot swap a shared photo"
SWAP="$(uuid).jpg"
SWAP_TOKEN=$(sign "$TOKEN_A" gym-photos "$SWAP" 'x-upsert: true')
post_object "$TOKEN_A" gym-photos "$SWAP" "$WORK/benign.jpg" >/dev/null
share "$TOKEN_A" "$GYM" barbell "$SWAP" >/dev/null
status=$(put_token gym-photos "$SWAP" "$SWAP_TOKEN" "$WORK/evil.jpg" 'x-upsert: true')
check "the swap is refused (got $status)" test "$status" != 200
check "the public bytes are unchanged" test "$(public_bytes "$SWAP")" = "$(cat "$WORK/benign.jpg")"

echo "Deleting your own photo and uploading again to its name is refused"
REUSE="$(uuid).jpg"
REUSE_TOKEN=$(sign "$TOKEN_A" gym-photos "$REUSE")
post_object "$TOKEN_A" gym-photos "$REUSE" "$WORK/benign.jpg" >/dev/null
share "$TOKEN_A" "$GYM" dumbbells "$REUSE" >/dev/null
curl -s -o /dev/null -X DELETE "$ST/object/gym-photos/$REUSE" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_A"
status=$(put_token gym-photos "$REUSE" "$REUSE_TOKEN" "$WORK/evil.jpg")
check "the re-upload is refused (got $status)" test "$status" != 200
check "no swapped bytes are served" test "$(public_bytes "$REUSE")" != "$(cat "$WORK/evil.jpg")"

echo "SVG cannot be stored through copy"
COPY_SRC="$(uuid).jpg"; COPY_DST="$(uuid).jpg"
post_object "$TOKEN_A" gym-photos "$COPY_SRC" "$WORK/benign.jpg" >/dev/null
curl -s -o /dev/null -X POST "$ST/object/copy" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_A" \
  -H 'Content-Type: application/json' \
  -d "{\"bucketId\":\"gym-photos\",\"sourceKey\":\"$COPY_SRC\",\"destinationKey\":\"$COPY_DST\",\"copyMetadata\":false,\"metadata\":{\"mimetype\":\"image/svg+xml\"}}"
check "no object holds the SVG type" test "$(psql_local -c "select count(*) from storage.objects
  where bucket_id = 'gym-photos' and metadata->>'mimetype' <> 'image/jpeg'" </dev/null)" = 0
check "the copy is not served as SVG" test "$(public_type "$COPY_DST")" != image/svg+xml

echo "A resumable upload with no content type is refused"
TUS_NAME="$(uuid).jpg"
meta="bucketName $(printf 'gym-photos' | base64),objectName $(printf '%s' "$TUS_NAME" | base64)"
location=$(curl -s -D - -o /dev/null -X POST "$ST/upload/resumable" -H "apikey: $ANON_KEY" \
  -H "Authorization: Bearer $TOKEN_A" -H 'Tus-Resumable: 1.0.0' -H "Upload-Length: $(wc -c < "$WORK/tiny.jpg" | tr -d ' ')" \
  -H "Upload-Metadata: $meta" | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}')
if [[ -n "$location" ]]; then
  curl -s -o /dev/null -X PATCH "$location" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_A" \
    -H 'Tus-Resumable: 1.0.0' -H 'Upload-Offset: 0' -H 'Content-Type: application/offset+octet-stream' \
    --data-binary "@$WORK/tiny.jpg"
fi
check "no object of that name is stored" test "$(psql_local -c "select count(*) from storage.objects
  where bucket_id = 'gym-photos' and name = '$TUS_NAME'" </dev/null)" = 0

echo "Tokens signed before the limit cannot all be used"
read -r TOKEN_C ID_C <<<"$(new_user c)"
: > "$WORK/tokens.txt"
for _ in $(seq 1 80); do
  name="$(uuid).jpg"; echo "$name $(sign "$TOKEN_C" gym-photos "$name")" >> "$WORK/tokens.txt"
done
while read -r name token; do put_token gym-photos "$name" "$token" "$WORK/tiny.jpg" >/dev/null; done < "$WORK/tokens.txt"
count=$(objects_of "$ID_C")
check "80 tokens signed at zero stored at most 60 ($count)" test "$count" -le 60
check "and not fewer than 60 ($count)" test "$count" -ge 60

echo "A token signed before the account was deleted is refused"
read -r TOKEN_D ID_D <<<"$(new_user d)"
DEAD_NAME="$(uuid).jpg"
DEAD_TOKEN=$(sign "$TOKEN_D" gym-photos "$DEAD_NAME")
rpc "$TOKEN_D" delete_my_account '{}' >/dev/null
status=$(put_token gym-photos "$DEAD_NAME" "$DEAD_TOKEN" "$WORK/tiny.jpg")
check "the upload is refused (got $status)" test "$status" != 200
check "nothing is owned by the deleted account" test "$(objects_of "$ID_D")" = 0

echo "An account that still owns a photo cannot be deleted (decision 5: the app removes the photos first)"
read -r TOKEN_F ID_F <<<"$(new_user f)"
KEPT="$(uuid).jpg"
post_object "$TOKEN_F" gym-photos-private "$KEPT" "$WORK/benign.jpg" >/dev/null
out=$(rpc "$TOKEN_F" delete_my_account '{}')
check "the server refuses with photos_remain (${out##*$'\n'})" grep -q photos_remain <<<"$out"
check "the account is still there" test "$(psql_local -c "select count(*) from auth.users where id = '$ID_F'" </dev/null)" = 1
curl -s -o /dev/null -X DELETE "$ST/object/gym-photos-private/$KEPT" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_F"
out=$(rpc "$TOKEN_F" delete_my_account '{}')
check "and it goes once the photo is removed (${out##*$'\n'})" test "$(psql_local -c "select count(*) from auth.users where id = '$ID_F'" </dev/null)" = 0

echo "100 parallel uploads leave at most 60 objects"
read -r TOKEN_E ID_E <<<"$(new_user e)"
export ST ANON_KEY TOKEN_E WORK
seq 1 100 | xargs -P 50 -I{} bash -c 'curl -s -o /dev/null -X POST "$ST/object/gym-photos/$(python3 -I -c "import uuid;print(uuid.uuid4())").jpg" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN_E" -H "Content-Type: image/jpeg" --data-binary "@$WORK/tiny.jpg"'
count=$(objects_of "$ID_E")
check "at most 60 stored ($count)" test "$count" -le 60
check "and 60 reached ($count)" test "$count" -ge 60

echo "Another user's photo cannot be overwritten or borrowed"
check "B cannot upload to A's used name" test "$(post_object "$TOKEN_B" gym-photos "$NORMAL" "$WORK/evil.jpg")" != 200
check "the public bytes are unchanged" test "$(public_bytes "$NORMAL")" = "$(cat "$WORK/benign.jpg")"

# Remove the files through the API where a token still works, then the rest by SQL in cleanup.
for pair in "$TOKEN_A $ID_A" "$TOKEN_C $ID_C" "$TOKEN_E $ID_E"; do
  set -- $pair
  for bucket in gym-photos gym-photos-private; do
    names=$(psql_local -c "select coalesce(json_agg(name), '[]') from storage.objects
      where owner_id = '$2' and bucket_id = '$bucket'" </dev/null)
    curl -s -o /dev/null -X DELETE "$ST/object/$bucket" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $1" \
      -H 'Content-Type: application/json' -d "{\"prefixes\": $names}"
  done
done

if [[ "$FAILS" -ne 0 ]]; then echo "$FAILS photo rule(s) failed" >&2; exit 1; fi
echo "Photo upload rules verified"

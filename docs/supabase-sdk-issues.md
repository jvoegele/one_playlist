# Defects found in the Supabase Elixir SDK

Bugs found in `supabase_potion`, `supabase_auth` and `supabase_storage` while building this
application against them.

The sibling of `docs/library-feedback.md`, which does the same for the four first-party
libraries. Separate from `docs/reference/supabase.md` on purpose: that file describes **how
Supabase works**, which stays true, while an entry here dies the day it is fixed. Mixing the two
means a reader cannot tell which notes they still have to design around.

Each entry carries a reproduction that runs with no network and no Supabase project, because
that is what makes it filable — and what lets us re-check it against a new release in one
command rather than by remembering.

**Upstream state, checked 2026-08-23:** both bugs below are still present on `main` (last
commits 2026-07-28) and both are now filed:

| | Issue |
| --- | --- |
| `Storage.File.list/3` | [storage-ex#36](https://github.com/supabase-community/storage-ex/issues/36) |
| Object paths are not URL encoded | [storage-ex#37](https://github.com/supabase-community/storage-ex/issues/37) |
| `get_claims/3` | [auth-ex#97](https://github.com/supabase-community/auth-ex/issues/97) |

The packages live in three separate repositories, which is worth knowing before looking for the
source: `supabase_potion` → `supabase-community/supabase-ex`, `supabase_auth` →
`supabase-community/auth-ex`, `supabase_storage` → `supabase-community/storage-ex`.

---

## `supabase_storage` — `Supabase.Storage.File.list/3` raises on every call

**Version:** 0.6.0, and `main` as of 2026-07-28 · **Filed:** [storage-ex#36](https://github.com/supabase-community/storage-ex/issues/36)

Listing objects is impossible. `SearchOptions.parse/1` raises before any request is made:

```elixir
Supabase.Storage.SearchOptions.parse(%{})
** (RuntimeError) casting embeds with cast/4 for :sort_by field is not supported,
   use cast_embed/3 instead
```

`Supabase.Storage.File.list/3` calls it on the way in, so the failure reaches every caller regardless of
arguments, bucket, or credentials.

Two separate mistakes in the same eight lines of `search_options.ex`:

```elixir
@fields ~w(limit offset sort_by search)a      # :sort_by is an embed, so cast/4 cannot take it

embeds_one :sort_by, SortBy, primary_key: false, defaults_to_struct: true do
  field(:column, :string, default: "name")
  field(:order, Ecto.Enum, values: [:asc, :desc], default: :asc)
end

def parse(attrs) do
  %__MODULE__{}
  |> cast(attrs, @fields)                                        # raises here
  |> cast_embed(:search_by, with: &search_by_changeset/2, required: true)
  |> apply_action(:parse)                                        # :search_by does not exist
end
```

`:sort_by` must come out of `@fields`, and the `cast_embed` names `:search_by` where the embed
is `:sort_by`. The second would raise as soon as the first was fixed, so a patch has to address
both — which is presumably why this was never caught: the first error masks the second.

**Impact here:** `OnePlaylist.Storage` has no `list/2`. It was written, found to be
unimplementable, and removed.

---

## `supabase_storage` — object paths are not URL encoded

**Version:** 0.6.0, and `main` as of 2026-07-28 · **Filed:** [storage-ex#37](https://github.com/supabase-community/storage-ex/issues/37)

An object whose name contains a space cannot be uploaded. The name goes into the request URI
unencoded, and the request never reaches Storage as a valid one.

```elixir
Supabase.Storage.File.upload(storage, "/tmp/local.csv", "u/imports/simple.csv")
# {:ok, ...}
Supabase.Storage.File.upload(storage, "/tmp/local.csv", "u/imports/Pearl Jam.csv")
# {:error, %Supabase.Error{code: :bad_request, message: "Unexpected"}}
```

Storage is not the problem. Against the same local stack, with the space encoded:

```
POST /storage/v1/object/playlists/probe/enc%20space.csv  ->  200
POST /storage/v1/object/playlists/probe/raw space.csv    ->  curl will not send it
```

`Supabase.Storage.File.upload/4`'s `clean_path` only strips and collapses slashes, so anything outside the
unreserved set survives into the URI. The same construction appears in `update/4`, `move/2`,
`copy/2` and `create_signed_url/3`.

**Impact here:** `OnePlaylist.Storage.path_for/3` reduces every object name to the RFC 3986
unreserved set, and carries a postcondition saying so. That is a defensible design on its own
merits, since a storage key and a filename a person reads are different things, but the reason
it exists now rather than later is this bug.

## `supabase_auth` — `get_claims/3` raises on most malformed tokens

**Version:** 1.0.0, and `main` as of 2026-07-28 · **Filed:** [auth-ex#97](https://github.com/supabase-community/auth-ex/issues/97)

The function's whole purpose is to decide whether a token is valid, so it is called precisely
where a token cannot be trusted. It raises instead of answering, and raises *differently*
depending on how the input is malformed:

```elixir
{:ok, client} = Supabase.init_client("http://127.0.0.1:54321", "any-key", %{})

Supabase.Auth.get_claims(client, "abc")            # ** (ArgumentError)
Supabase.Auth.get_claims(client, "")               # ** (ArgumentError)
Supabase.Auth.get_claims(client, "not.a.jwt")      # ** (CaseClauseError)
Supabase.Auth.get_claims(client, "a.b.c")          # ** (CaseClauseError)
Supabase.Auth.get_claims(client, "aaaa.bbbb.cccc") # ** (Jason.DecodeError)

Supabase.Auth.get_claims(client, "eyJhbGciOiJIUzI1NiJ9.e30.x")
# {:error, :invalid_jwt_format}                      <- the documented answer
```

None of these touches the network.

The last line is what makes this a bug rather than an undocumented convention: the error tuple
**is** returned, for a token whose three segments decode but do not describe a JWT. So the
contract is real and is simply not honoured for the commoner failures — `decode_jwt_parts/1`
calls `JOSE.JWT.peek/1` first, and that raises on input the `with`'s `else` clause was written
to catch.

The `@spec` says `{:ok, …} | {:error, term()}`, so a caller has no reason to expect otherwise.

**Suggested fix:** wrap the decoding in `try/rescue` inside `decode_jwt_parts/1` and return
`{:error, :invalid_jwt_format}`, which the function already does for the case it happens to
survive. Three exception types from one input class also suggests a property test over arbitrary
binaries would be worth having.

**Impact here:** `OnePlaylist.Accounts.claims/1` wraps every call in `rescue`, which is not
something a caller should have to do for a function that reports failure as `{:error, _}` most
of the time.

---

## `supabase_auth` — a PKCE magic link discards its own verifier, and never sends the challenge

**Version:** 1.0.0 · **Found:** 2026-09-02 · **Filed:** not yet

`Supabase.Auth.sign_in_with_otp/2` on a client whose `auth.flow_type` is `:pkce` cannot
produce a magic link anybody can finish. Two independent defects, either of which is enough:

```elixir
# lib/supabase/auth/user_handler.ex
def sign_in_with_otp(%Client{} = client, %SignInWithOTP{} = signin) when client.auth.flow_type == :pkce do
  {_verifier, challenge, method} = generate_pkce()        # <- the verifier is dropped here
  with {:ok, body} <- SignInRequest.create(signin, challenge, method) do
    ...
    |> then(fn {:ok, _resp} -> :ok end)                    # <- and the caller gets a bare :ok
```

The function's return is `:ok`. The verifier — the one secret the whole flow depends on —
exists for the duration of the call and is never handed to the caller, so when GoTrue later
redirects back with `?code=…` there is nothing to give `exchange_code_for_session/4`.

The second defect means GoTrue never learns there *was* a challenge:

```elixir
# lib/supabase/auth/schemas/sign_in_with_otp.ex
|> Map.merge(%{code_challange: code_challenge, code_challenge_method: code_method})
#              ^^^^^^^^^^^^^^ misspelt

# lib/supabase/auth/schemas/sign_in_request.ex — the 3-arity `create/3` for OTP
|> cast(attrs, [:email, :phone, :data, :create_user, :redirect_to, :channel])
#              neither :code_challenge nor :code_challenge_method is cast
```

So the request body GoTrue receives is identical to the implicit-flow one. The same shape
appears in `sign_up/2`, `sign_in_with_sso/2` and `reset_password_for_email/3`, each of which
calls `generate_pkce/0` and binds the verifier to `_verifier`. Only `sign_in_with_oauth/2`
(`get_data_for_provider/2`) returns it, and it does so correctly.

Reproduced with no network — the return type says it all:

```elixir
{:ok, client} = Supabase.init_client("http://127.0.0.1:54321", "any-key", %{auth: %{flow_type: :pkce}})
{:ok, signin} = Supabase.Auth.Schemas.SignInWithOTP.parse(%{email: "a@b.test"})
{:ok, body} = Supabase.Auth.Schemas.SignInRequest.create(signin, "challenge", "s256")
Map.has_key?(body, :code_challenge)  # true — the field exists on the struct
body.code_challenge                  # nil  — it was never cast
```

**Suggested fix:** return `{:ok, %{code_verifier: verifier}}` from the PKCE clause (a breaking
change to a return that is currently `:ok`, so probably behind the flow type), fix the spelling,
and add both fields to the cast list. A test that asserts on the outgoing body would have caught
all three.

**Impact here:** none in the end, and for a reason worth recording. The application's magic link
does not use PKCE at all — it uses GoTrue's `token_hash` flow, which is what Supabase documents
for server-rendered applications and which works from a different browser than the one that
asked for the link. That was the right design before the defect was found. But the defect is
what makes `OnePlaylist.Supabase.client/1` default to `:implicit` and hand out a `:pkce` client
only to `begin_google_sign_in/1`: a shared `:pkce` client would send every sign-up confirmation
email as a code nobody can exchange. See that function's documentation.

---

## `supabase_potion` — `init_client/3`'s options typespec rejects the documented call

**Version:** 0.8.0 · **Found:** 2026-09-02 · **Filed:** not yet

The docstring for `Supabase.init_client/3` shows:

```elixir
Supabase.init_client(url, key, auth: [flow_type: :pkce])
```

The `@spec` says `options :: Supabase.Client.options()`, which is

```elixir
@type options :: %{optional(:auth) => Supabase.Client.Auth.params(), ...}   # a map, fine
@type params  :: %{auto_refresh_token: boolean(), debug: boolean(), detect_session_in_url: boolean(),
                   flow_type: String.t(), persist_session: boolean(), storage_key: String.t()}
```

Every key of `params` is **required** — there is no `optional(...)` — and `flow_type` is a
`String.t()`, where the schema field is `Ecto.Enum` over `~w[implicit pkce magicLink]a` and the
documented value is an atom. So the documented keyword list breaks the contract twice over, a
map with just `flow_type` breaks it once, and there is no value a caller wanting only to set
the flow type can pass that Dialyzer accepts. The runtime is fine with all of them: it calls
`Map.new/1` and runs the map through the changeset.

Reproduced with no network:

```elixir
# in any module with a @spec that Dialyzer checks
Supabase.init_client("http://127.0.0.1:54321", "key", auth: [flow_type: :pkce])
# lib/…: The function call will not succeed. … breaks the contract … options: Supabase.Client.options()
```

**What it costs.** Dialyzer's success typing for the calling function collapses to the error
branch, and every caller's `{:ok, _}` pattern is then reported as one that "can never match".
In this application that was **45 findings** across `Accounts`, `Storage`, `Imports`, `Exports`
and two controllers, from a single argument.

**Suggested fix:** make every key in `Auth.params()` (and the sibling `Db`/`Global`/`Storage`
params) `optional(...)`, type `flow_type` as `:implicit | :pkce | :magicLink`, and either widen
`options` to accept a keyword list or change the docstring to pass a map.

**Impact here:** `OnePlaylist.Supabase.client/1` builds the client with `%{}` and sets the flow
type on the struct afterwards, which is a workaround and is commented as one.

---

## Things that are not bugs, and are not filed

Kept here so the list above stays credible. Each is recorded in `docs/reference/supabase.md`
where a reader designing against the platform will meet it.

  * **`Supabase.Error.code` is the HTTP status class, not the service's answer.** GoTrue's real
    `error_code` and Storage's real `statusCode` are both in `metadata.resp_body`. Arguably by
    design — the default parser is documented as status-based, and services are meant to install
    their own — but neither `supabase_auth` nor `supabase_storage` does, so every caller has to.
    An enhancement request rather than a defect.
  * **`sign_out` lives under `Supabase.Auth.Admin`.** It is `POST /logout` with the user's own
    token and needs no service role key. Naming, not behaviour.
  * **`supabase_auth 1.0.0` requires `supabase_potion ~> 0.7`.** Surprising when both are
    published at 1.0, and it makes `{:supabase_potion, "~> 1.0"}` fail resolution. Intentional
    as far as anyone can tell; what misled us was a version table in our own reference doc.
  * **`Supabase.Auth.Session` derives a JSON encoder** covering `provider_token` and
    `provider_refresh_token`. Not a defect, but it means the struct holding a user's third-party
    credentials serialises them by default. Worth a redaction, and worth raising if the other two
    are filed.

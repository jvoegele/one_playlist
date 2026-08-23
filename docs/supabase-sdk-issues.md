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

**Upstream state, checked 2026-08-23:** `supabase-community/storage-ex` and
`supabase-community/auth-ex` each have **zero open issues**, and both bugs below are still
present on `main` (last commits 2026-07-28). Neither is reported.

The packages live in three separate repositories, which is worth knowing before looking for the
source: `supabase_potion` → `supabase-community/supabase-ex`, `supabase_auth` →
`supabase-community/auth-ex`, `supabase_storage` → `supabase-community/storage-ex`.

---

## `supabase_storage` — `Supabase.Storage.File.list/3` raises on every call

**Version:** 0.6.0, and `main` as of 2026-07-28 · **Status:** not reported

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

**That it ships at all suggests the function has no test**, since any call in any test would
fail.

**Impact here:** `OnePlaylist.Storage` has no `list/2`. It was written, found to be
unimplementable, and removed.

---

## `supabase_auth` — `get_claims/3` raises on most malformed tokens

**Version:** 1.0.0, and `main` as of 2026-07-28 · **Status:** not reported

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

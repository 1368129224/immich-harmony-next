# Native iOS API baseline

Official Immich release: v3.2.4 (`db355f79d910bbfc6378117ed10868493c97b922`).
Source: https://raw.githubusercontent.com/immich-app/immich/v3.2.4/open-api/immich-openapi-specs.json
SHA256: `0583d80f74f2f3997e573c618195c4945b399afb00da15570888254e72654d5a`.

The native client uses the pinned official source above as its API baseline;
`openapi/immich-openapi-specs.json` is retained as a reference snapshot.
New native request shapes must match the pinned official source. This Swift vertical slice implements only
`/timeline/buckets`, `/timeline/bucket`, `/search/metadata`, and `/albums`, not
the complete v3.2.4 client. See `docs/ios-native-design.md` for the remaining
migration and acceptance criteria.

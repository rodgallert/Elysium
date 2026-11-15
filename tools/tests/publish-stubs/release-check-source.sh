#!/usr/bin/env bash
# Test stand-in for tools/release-check-source.sh in the release-publish.sh cases (the real check has its own cases
# through release-state.sh): the attestation and source checks pass. Refuses to run outside the tests.
[ "${RELEASE_TOOLS_TEST:-}" = 1 ] || { echo "tools/tests/publish-stubs/release-check-source.sh is a test stub" >&2; exit 99; }
exit 0

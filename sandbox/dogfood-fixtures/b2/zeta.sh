#!/bin/bash
# b2 dogfood fixture: zeta module — composes delta + epsilon.
_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_dir/delta.sh"
# shellcheck source=/dev/null
. "$_dir/epsilon.sh"
b2_zeta() { echo "$(b2_delta) $(b2_epsilon) b2-zeta"; }

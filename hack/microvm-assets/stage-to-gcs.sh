#!/usr/bin/env bash

# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Stage the assembled micro-VM asset set into the GCS asset bucket under
# kata-assets/, where atelet fetches it through the node's object-store plugin
# (per manifests/microvm/sandboxconfig-microvm.yaml.tmpl). The plugin refuses
# assets stored under a snapshot location (<snapshotConfig.location>/atespaces/),
# so keep them outside it. The GKE counterpart of stage-to-rustfs.sh. Run after
# assemble.sh has produced $OUT.
#
# Requires the `gcloud` CLI authenticated for the bucket's project. Env: OUT (asset
# dir, default ./bin/microvm-assets/amd64), BUCKET (required, the asset bucket,
# BUCKET_NAME-assets as install-microvm-deps.sh passes it), PROJECT_ID (optional;
# passed to gcloud as --project when set).

set -o errexit -o nounset -o pipefail

ROOT="$(git rev-parse --show-toplevel)"

OUT="${OUT:-${ROOT}/bin/microvm-assets/amd64}"
BUCKET="${BUCKET:?set BUCKET to the asset bucket, BUCKET_NAME-assets}"

# Pass --project only when PROJECT_ID is set (mirrors hack/teardown.sh); otherwise
# gcloud uses its active config project. ${PROJECT_ID:+...} elides the flag entirely
# when unset (same idiom as KUBECTL_CONTEXT in hack/run-microvm-demo.sh).
if ! gcloud storage buckets describe ${PROJECT_ID:+--project="${PROJECT_ID}"} "gs://${BUCKET}" >/dev/null 2>&1; then
  loc="${CLUSTER_LOCATION:-us-central1}"
  if [[ "${loc}" =~ ^[a-z]+-[a-z0-9]+-[a-z]$ ]]; then
    loc="${loc%-*}"
  fi
  echo ">> Asset bucket gs://${BUCKET} does not exist; creating in ${loc} and granting objectViewer to atelet..."
  gcloud storage buckets create ${PROJECT_ID:+--project="${PROJECT_ID}"} --location="${loc}" --uniform-bucket-level-access "gs://${BUCKET}" --quiet || true
  if [[ -n "${PROJECT_ID:-}" ]]; then
    proj_num="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)' 2>/dev/null || true)"
    if [[ -n "${proj_num}" ]]; then
      atelet_wi="principal://iam.googleapis.com/projects/${proj_num}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/ate-system/sa/atelet"
      node_sa="serviceAccount:${proj_num}-compute@developer.gserviceaccount.com"
      gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" --member="${atelet_wi}" --role="roles/storage.objectViewer" --quiet >/dev/null 2>&1 || true
      gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" --member="${node_sa}" --role="roles/storage.objectViewer" --quiet >/dev/null 2>&1 || true
    fi
  fi
fi

echo ">> Uploading assets to gs://${BUCKET}/kata-assets/ ..."
for f in cloud-hypervisor virtiofsd vmlinux rootfs.img; do
  echo "   $f"
  gcloud storage cp ${PROJECT_ID:+--project="${PROJECT_ID}"} "${OUT}/${f}" "gs://${BUCKET}/kata-assets/${f}"
done

echo ">> Done. Verify:"
gcloud storage ls ${PROJECT_ID:+--project="${PROJECT_ID}"} "gs://${BUCKET}/kata-assets/"

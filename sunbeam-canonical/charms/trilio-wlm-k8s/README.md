# trilio-wlm-k8s

TrilioVault WorkloadManager (wlm-api, wlm-workloads, wlm-scheduler, wlm-cron) with the embedded DMS server, as a Kubernetes charm for Sunbeam.

## Build and publish

This charm is built and published to Charmhub as `trilio-wlm-k8s` by the `sunbeam-charms-build-publish.yml` GitHub Actions workflow. A merge that changes this directory on the release branch builds only this charm and releases it to the channel in the `CHARMHUB_DEFAULT_CHANNEL` repository variable. To rebuild it without a code change, change the UUID in the `rebuild` file.

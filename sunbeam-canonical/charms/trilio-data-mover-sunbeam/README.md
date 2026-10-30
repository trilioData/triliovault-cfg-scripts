# trilio-data-mover-sunbeam

TrilioVault Data Mover and DMS server as a machine subordinate charm of openstack-hypervisor on Sunbeam compute nodes.

## Build and publish

This charm is built and published to Charmhub as `trilio-data-mover-sunbeam` by the `sunbeam-charms-build-publish.yml` GitHub Actions workflow. A merge that changes this directory on the release branch builds only this charm and releases it to the channel in the `CHARMHUB_DEFAULT_CHANNEL` repository variable. To rebuild it without a code change, change the UUID in the `rebuild` file.

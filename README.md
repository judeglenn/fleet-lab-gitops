# Fleet GitOps Lab

A self-hosted [Fleet](https://fleetdm.com) lab where device management configuration is managed as code. I built it to practice the change discipline used for production fleets: every change is reviewed, validated automatically, applied automatically, and corrected if it drifts.

This is a home lab. It manages one macOS virtual machine. The limits are listed below.

## Architecture

```mermaid
flowchart LR
    Dev[Branch and pull request] --> GH[GitHub repo]
    GH -->|PR: dry run| CI[GitHub Actions]
    GH -->|merge to main: apply| CI
    Cron[Nightly schedule] --> CI
    CI -->|fleetctl gitops| Fleet[Fleet server on Railway]
    Fleet --- MySQL[(MySQL)]
    Fleet --- Redis[(Redis)]
    Fleet <-->|MDM and osquery| Host[macOS 27 VM]
```

- **Fleet server:** `fleetdm/fleet` container on Railway, pinned to an exact version.
- **MySQL and Redis:** Railway services, pinned to exact versions, reachable only over Railway's private network. No public access.
- **Apple MDM:** enabled with an APNs certificate issued to a personal Apple ID.
- **Host:** one macOS 27 virtual machine running fleetd, used as the canary.
- **Image auto-updates are off for Fleet, MySQL, and Redis.** A version change is a deliberate change.

## How a change ships

1. Create a branch and edit the YAML or a file under `lib/`.
2. Open a pull request. The description states the expected end state before anything changes.
3. CI runs `fleetctl gitops --dry-run`. Pull requests never apply.
4. Merge to main. CI runs the dry run again, then applies.
5. Verify the result on the server or the device, not just the green check.
6. A nightly scheduled run re-applies the repo, so changes made outside Git are overwritten within a day.

The Fleet server URL, API token, and enroll secret live in GitHub Actions secrets. The YAML only references them as environment variables.

## Guardrails

**Branch protection on main**

- Pull request required to merge.
- The `fleet-gitops` CI check must pass.
- Force pushes blocked. Branch deletion blocked.
- Bypass list empty.

Tested: a direct push to main is rejected with `push declined due to repository rule violations`.

**CI fails closed**

Fleet's starter GitHub Action installs a `fleetctl` version matched to the server. If it could not read the server version, it fell back to a hardcoded default version. If installing the matched version failed, it fell back to `fleetctl@latest`. Either way the job continued and could still pass.

I removed both fallbacks in [`.github/gitops-action/action.yml`](.github/gitops-action/action.yml). Now, if the server version can't be read or the matching `fleetctl` can't be installed, the job stops. For a tool that pushes configuration to every managed device, a run with an unverified tool version should fail, not proceed.

## Example change

**Disable Fleet usage analytics** ([pull request #1](https://github.com/judeglenn/fleet-lab-gitops/pull/1)).

- Change: `enable_analytics: true` to `false` in `default.yml`.
- Expected end state written in the pull request before merging.
- Pull request run: dry run only. Merge run: applied.
- Verified afterward in Fleet under Settings, Organization settings, Usage statistics: unchecked. My predicted location in the pull request was wrong (I expected Advanced options).

## Limits

- **Scale.** One VM. This shows the workflow, not fleet-scale operation.
- **Solo review.** Pull requests require zero approvals, because GitHub doesn't let you approve your own. Branch protection still blocks direct pushes, and CI still gates every merge.
- **Admin CI token.** On Fleet's free tier, the CI user has to be a global admin. A narrower GitOps role is a Premium feature. The token lives only in GitHub secrets.
- **Console not locked.** Fleet's GitOps-only console mode is Premium. Changes made in the console are overwritten by the next apply, but they are not blocked.
- **Drift is corrected, not detected.** Fleet's dry-run output lists every section it would apply, including "would've updated 4 labels" on a configuration exported from the live server. It doesn't show what actually differs, so the nightly run fixes drift without reporting it.
- **No profile enforced on a device yet.** A firewall profile is defined in this repo and listed in Fleet, but it has not been delivered to the VM. See the open issue below.

## Open issue: profile delivery

The firewall profile ([pull request #2](https://github.com/judeglenn/fleet-lab-gitops/pull/2)) merged and appeared in Fleet under Controls, OS settings, but never reached the VM. Fleet's console showed the VM's MDM status as "On (manual)."

What I checked, in order:

1. **Device, via osquery.** A live query of `managed_policies` for firewall settings returned no rows. The Mac never received the profile.
2. **MDM commands.** `fleetctl get mdm-commands` reported that no MDM commands had ever been run on this host.
3. **Server state.** `fleetctl get host` showed `enrollment_status: On (manual)` alongside `connected_to_fleet: false`.
4. **Server logs.** The Apple profile manager ran every cycle and completed without errors, yet no MDM command was ever created for this host.
5. **HTTP logs.** Every MDM check-in request from the VM to `/mdm/apple/mdm` returned status 200.
6. **MDM database.** `nano_devices` had one row. `nano_enrollments` was empty. In Apple's MDM check-in flow, the enrollment record comes from the TokenUpdate message, which carries the device's push token.
7. **Device logs.** `mdmclient` repeatedly logged `Connection Invalid for service com.apple.apsd`. The push daemon (`apsd`) itself was running.

Ruled out by evidence:

- **Enrollment order.** Re-enrolling the VM with fleetd already installed did not change it. `connected_to_fleet` stayed `false` and `nano_enrollments` stayed empty.
- **The wrong database.** The `hosts` table held the expected host record.
- **The hosting proxy stripping device identity.** The device record in `nano_devices` shows the identity check-in was processed.
- **A failing profile manager.** It ran cleanly every cycle.

**Current status: traced to the push token step (TokenUpdate) never producing an enrollment, with `mdmclient` unable to reach `apsd` on the VM. The cause is not yet confirmed.** The confirmation test is enrolling a physical Mac the same way.

Lessons:

- The console showed the device's own MDM status. The server's `connected_to_fleet` field said otherwise.
- A 200 response means the request was received, not that it was processed.
- After MDM enrollment, fleetd did not install itself, so I installed it by hand. Fleet also never sent this host any MDM command, so the missing install may have been an early sign of the same problem.

## Next

- Enroll a physical Mac to confirm or rule out the push token cause.
- Add drift detection: export the live configuration nightly, diff it against the repo, and fail with the diff before re-applying.
- Roll back a deliberately bad change by reverting its pull request, and verify removal on the device.
- Add a Linux host and manage a Linux policy through the same pipeline.
- Separate staging and production instances, with changes promoted between them.

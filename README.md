# Password-Manager
Using bitwarden extension to allow for chromium and safari browers, these passwords are synced across devices. The service is run on docker


------------
IS NOT COMPLETE
------------

------------
Internet ──> Cloudflare edge ──(outbound-only tunnel)──> cloudflared container
                                                              │ internal docker network
                                                              ▼   (no host route)
                                                    vaultwarden container
                                                              │
                                                        ./vw-data
                                                              │
                                        Debian VM on Proxmox ─┴─> nightly encrypted backups
------------


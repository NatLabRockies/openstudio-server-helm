#!/usr/bin/env python3
"""Log Docker into a Pulp container registry using a Keycloak device-flow token.

Requires the `requests` package (pip install requests) and the docker CLI.

Example:
  scripts/pulp_login.py \\
    --registry pulp.example.org \\
    --keycloak-url https://sso.example.org/realms/myrealm \\
    --client-id pulp-client

Every option can also be set via an environment variable (PULP_REGISTRY,
PULP_KEYCLOAK_URL, PULP_CLIENT_ID, PULP_TOKEN_URL, PULP_DEVICE_URL,
PULP_USERNAME).
"""
import argparse
import os
import requests
import sys
import time
import subprocess
import webbrowser


def parse_args():
    env = os.environ.get
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--registry", default=env("PULP_REGISTRY"),
                   help="Registry host to docker login to (env: PULP_REGISTRY)")
    p.add_argument("--client-id", default=env("PULP_CLIENT_ID"),
                   help="Keycloak client id (env: PULP_CLIENT_ID)")
    p.add_argument("--keycloak-url", default=env("PULP_KEYCLOAK_URL"),
                   help="Keycloak realm URL, e.g. https://sso.example.org/realms/myrealm; "
                        "token and device endpoints are derived from it (env: PULP_KEYCLOAK_URL)")
    p.add_argument("--token-url", default=env("PULP_TOKEN_URL"),
                   help="Override the token endpoint (env: PULP_TOKEN_URL)")
    p.add_argument("--device-url", default=env("PULP_DEVICE_URL"),
                   help="Override the device authorization endpoint (env: PULP_DEVICE_URL)")
    p.add_argument("--username", default=env("PULP_USERNAME"),
                   help="Registry username; prompted if omitted (env: PULP_USERNAME)")
    args = p.parse_args()

    if args.keycloak_url:
        base = args.keycloak_url.rstrip("/") + "/protocol/openid-connect"
        args.token_url = args.token_url or base + "/token"
        args.device_url = args.device_url or base + "/auth/device"

    missing = [name for name, val in (
        ("--registry", args.registry),
        ("--client-id", args.client_id),
        ("--token-url (or --keycloak-url)", args.token_url),
        ("--device-url (or --keycloak-url)", args.device_url),
    ) if not val]
    if missing:
        p.error("missing required option(s): " + ", ".join(missing))
    return args


def device_login(args):
    """
    Performs the OAuth 2.0 Device Authorization Grant flow.
    """
    try:
        # 1. Request Device Authorization Code
        print(f"[*] Initializing login for client: {args.client_id}", file=sys.stderr)
        resp = requests.post(
            args.device_url,
            data={
                "client_id": args.client_id,
                "scope": "openid profile email",
            },
            timeout=10
        )
        resp.raise_for_status()
        data = resp.json()

        user_code = data.get("user_code")
        verification_uri = data.get("verification_uri")
        device_code = data.get("device_code")

        if not all([user_code, verification_uri, device_code]):
            print("[-] Error: Received incomplete device authorization response.", file=sys.stderr)
            sys.exit(1)

        # 2. Display instructions to the user
        print(f"\n[!] ACTION REQUIRED", file=sys.stderr)
        print(f"    1. Open your browser and go to: {verification_uri}", file=sys.stderr)
        print(f"    2. Enter the following code: {user_code}", file=sys.stderr)
        print(f"    3. Complete the PIV/2FA authentication in the browser.", file=sys.stderr)
        print(f"\n[*] Attempting to open browser...", file=sys.stderr)

        # 3. Automatically open browser
        webbrowser.open(verification_uri)

        # 4. Poll the token endpoint until the user is authenticated
        print(f"[*] Waiting for authentication...", file=sys.stderr)
        while True:
            time.sleep(5)

            token_resp = requests.post(
                args.token_url,
                data={
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    "device_code": device_code,
                    "client_id": args.client_id,
                },
                timeout=10
            )

            if token_resp.status_code == 200:
                token_data = token_resp.json()
                print("[+] Authentication successful!", file=sys.stderr)
                return token_data.get("access_token")

            elif token_resp.status_code == 400:
                error_msg = token_resp.text.lower()
                if "authorization_pending" in error_msg:
                    continue
                elif "slow_down" in error_msg:
                    time.sleep(10)
                    continue
                elif "expired" in error_msg:
                    print("[-] Error: Device code has expired. Please run the command again.", file=sys.stderr)
                    sys.exit(1)
                else:
                    print(f"[-] Error from Keycloak: {token_resp.text}", file=sys.stderr)
                    sys.exit(1)
            else:
                print(f"[-] Unexpected error: {token_resp.status_code} - {token_resp.text}", file=sys.stderr)
                sys.exit(1)

    except Exception as e:
        print(f"[-] An unexpected error occurred: {e}", file=sys.stderr)
        sys.exit(1)

def main():
    args = parse_args()
    # 1. Prompt for username
    username = (args.username or input("Enter your username for {}: ".format(args.registry))).strip()
    if not username:
        print("[-] Username cannot be empty.", file=sys.stderr)
        sys.exit(1)

    # 2. Run the device flow to get the token
    token = device_login(args)

    if not token:
        print("[-] Failed to retrieve token.", file=sys.stderr)
        sys.exit(1)

    # 3. Use the token to log into docker via stdin
    print(f"[*] Logging into {args.registry} as user '{username}'...", file=sys.stderr)

    try:
        # We use subprocess.run with input=token to mimic: echo $TOKEN | docker login ... -p -
        result = subprocess.run(
            ["docker", "login", args.registry, "-u", username, "--password-stdin"],
            input=token,
            capture_output=True,
            text=True
        )

        if result.returncode == 0:
            print(f"[+] SUCCESS: Logged into {args.registry}")
        else:
            print(f"[-] ERROR: Docker login failed:\n{result.stderr}", file=sys.stderr)
            sys.exit(1)

    except Exception as e:
        print(f"[-] Error executing docker: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()

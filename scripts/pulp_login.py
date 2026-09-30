#!/usr/bin/env python3
import requests
import sys
import time
import subprocess
import webbrowser

# --- CONFIGURATION ---
CLIENT_ID = "pulp-dev"
TOKEN_URL = "https://sso.hpc.nlr.gov/realms/nlrcsc/protocol/openid-connect/token"
DEVICE_URL = "https://sso.hpc.nlr.gov/realms/nlrcsc/protocol/openid-connect/auth/device"
TARGET_HOST = "pulp-dev.hpc.nlr.gov"
# ---------------------

def device_login():
    """
    Performs the OAuth 2.0 Device Authorization Grant flow.
    """
    try:
        # 1. Request Device Authorization Code
        print(f"[*] Initializing login for client: {CLIENT_ID}", file=sys.stderr)
        resp = requests.post(
            DEVICE_URL,
            data={
                "client_id": CLIENT_ID,
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
                TOKEN_URL,
                data={
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    "device_code": device_code,
                    "client_id": CLIENT_ID,
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
    # 1. Prompt for username
    username = input("Enter your username for {}: ".format(TARGET_HOST)).strip()
    if not username:
        print("[-] Username cannot be empty.", file=sys.stderr)
        sys.exit(1)

    # 2. Run the device flow to get the token
    token = device_login()

    if not token:
        print("[-] Failed to retrieve token.", file=sys.stderr)
        sys.exit(1)

    # 3. Use the token to log into docker via stdin
    print(f"[*] Logging into {TARGET_HOST} as user '{username}'...", file=sys.stderr)

    try:
        # We use subprocess.run with input=token to mimic: echo $TOKEN | docker login ... -p -
        result = subprocess.run(
            ["docker", "login", TARGET_HOST, "-u", username, "--password-stdin"],
            input=token,
            capture_output=True,
            text=True
        )

        if result.returncode == 0:
            print(f"[+] SUCCESS: Logged into {TARGET_HOST}")
        else:
            print(f"[-] ERROR: Docker login failed:\n{result.stderr}", file=sys.stderr)
            sys.exit(1)

    except Exception as e:
        print(f"[-] Error executing docker: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
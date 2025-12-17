#!/usr/bin/env python3
#
# *******************************************************************************
# Copyright (c) 2025 Contributors to the Eclipse Foundation
#
# See the NOTICE file(s) distributed with this work for additional
# information regarding copyright ownership.
#
# This program and the accompanying materials are made available under the
# terms of the Apache License Version 2.0 which is available at
# https://www.apache.org/licenses/LICENSE-2.0
#
# SPDX-License-Identifier: Apache-2.0
# *******************************************************************************
"""
Helper to obtain a QNX login cookie for authenticated downloads.

Reads JSON from stdin of the form: {"uri": "<qnx download url>"}
Emits JSON with headers that include the myQNX cookie, suitable for tooling like curl.
Uses SCORE_QNX_USER / SCORE_QNX_PASSWORD env vars or falls back to ~/.netrc entry for "qnx.com".
"""

import http.cookiejar
import json
import netrc
import os
import sys
import urllib.parse
import urllib.request


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def main():
    data = json.load(sys.stdin)
    uri = data.get("uri", "")

    if "qnx.com" not in uri:
        eprint("Unsupported domain (expected qnx.com)")
        sys.exit(1)

    # Credentials
    if "SCORE_QNX_USER" in os.environ and "SCORE_QNX_PASSWORD" in os.environ:
        login = os.environ["SCORE_QNX_USER"]
        password = os.environ["SCORE_QNX_PASSWORD"]
    else:
        try:
            nrc = netrc.netrc()
            auth = nrc.authenticators("qnx.com")
            if auth:
                login, _, password = auth
            else:
                raise Exception("No credential found for QNX")
        except Exception as excp:
            eprint(excp)
            eprint("Failed getting credentials from .netrc")
            sys.exit(1)

    form_data = urllib.parse.urlencode(
        {"userlogin": login, "password": password, "UseCookie": "1"}
    ).encode("ascii")

    cookie_jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cookie_jar))
    urllib.request.install_opener(opener)

    r = urllib.request.urlopen("https://www.qnx.com/account/login.html", form_data)
    if r.status != 200:
        eprint("Failed to login to QNX")
        sys.exit(1)

    cookies = {c.name: c.value for c in cookie_jar}
    if "myQNX" not in cookies:
        eprint("Failed to get myQNX cookie from login page")
        sys.exit(1)

    myqnx = cookies["myQNX"]
    print(
        json.dumps(
            {
                "headers": {
                    "Cookie": [f"myQNX={myqnx}"],
                }
            }
        )
    )


if __name__ == "__main__":
    main()

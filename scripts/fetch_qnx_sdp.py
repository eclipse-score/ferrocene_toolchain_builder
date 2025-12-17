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
Login to qnx.com and download an SDP (or any authenticated asset) to a local file.

Usage:
  ./scripts/fetch_qnx_sdp.py <url> <output_path>

Credentials are taken from SCORE_QNX_USER / SCORE_QNX_PASSWORD or from ~/.netrc entry for "qnx.com".
"""

import http.cookiejar
import netrc
import os
import sys
import urllib.parse
import urllib.request
import shutil


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def get_credentials():
    user = os.environ.get("SCORE_QNX_USER")
    password = os.environ.get("SCORE_QNX_PASSWORD")
    if user and password:
        return user, password
    try:
        nrc = netrc.netrc()
        auth = nrc.authenticators("qnx.com")
        if auth:
            login, _, password = auth
            return login, password
    except Exception:
        pass
    raise SystemExit(
        "No credentials found (set SCORE_QNX_USER / SCORE_QNX_PASSWORD or ~/.netrc for qnx.com)"
    )


def login(opener, cookie_jar):
    user, password = get_credentials()
    form_data = urllib.parse.urlencode(
        {"userlogin": user, "password": password, "UseCookie": "1"}
    ).encode("ascii")
    resp = opener.open("https://www.qnx.com/account/login.html", form_data)
    if resp.status != 200:
        raise SystemExit("Failed to login to QNX (status %s)" % resp.status)
    cookies = {c.name: c.value for c in cookie_jar}
    if "myQNX" not in cookies:
        raise SystemExit("Login succeeded but myQNX cookie was not issued; check credentials.")


def download_with_cookies(url, dest):
    cookie_jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cookie_jar))
    urllib.request.install_opener(opener)

    login(opener, cookie_jar)

    with opener.open(url) as r:
        first = r.read(4)
        content_type = r.headers.get("Content-Type", "")
        if first[:2] != b"\x1f\x8b":
            snippet = first + r.read(256)
            text = snippet.decode("utf-8", errors="replace")
            raise SystemExit(
                "Download did not look like gzip (Content-Type: %s). "
                "Got response:\n%s" % (content_type, text)
            )
        with open(dest, "wb") as f:
            f.write(first)
            shutil.copyfileobj(r, f)


def main():
    if len(sys.argv) != 3:
        eprint("Usage: fetch_qnx_sdp.py <url> <output_path>")
        sys.exit(1)
    url = sys.argv[1]
    dest = sys.argv[2]
    if "qnx.com" not in url:
        eprint("Expected a qnx.com URL")
        sys.exit(1)
    download_with_cookies(url, dest)
    print(f"Downloaded {url} -> {dest}")


if __name__ == "__main__":
    main()

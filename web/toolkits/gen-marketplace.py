#!/usr/bin/env python3
"""
gen-marketplace.py — build the Workbooks toolkit MARKETPLACE (workbooks.sh/toolkits/).

Reads every  toolkits/<slug>/manifest.org  and emits, into  web/toolkits/ :
  1. catalog.json                — machine catalog [{slug,title,tagline,version,kind,caps[],integration?,category,logo}]
  2. index.html                  — the marketplace: hero + responsive card grid + client-side search/filter
  3. <slug>.html                 — a Zapier-style detail page per toolkit

This is the MARKETPLACE on the main site (logos, cards, per-toolkit pages),
distinct from docs.workbooks.sh. Brand = the landing page (workbooks.sh):
paper #f7f6f1, ink #121316, Franie display (sentence-case SemiBold), JetBrains
Mono body — all sans/mono, NO serif, NO green. Color comes from the BRAND PASTELS used as
fills behind ink text. The nav pill is mounted from /nav.js.

No third-party deps — stdlib only.  Run:  python3 web/toolkits/gen-marketplace.py
"""

import json
import os
import re
import html
from datetime import datetime, timezone

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
TK_DIR = os.path.join(ROOT, "toolkits")
OUT_DIR = os.path.join(ROOT, "web", "toolkits")
RELEASES = os.path.join(TK_DIR, "releases.json")

# toolkits that are NOT live yet — skip entirely (no card, no detail page)
EXCLUDE = {"brandnana", "3w"}

# ── brand pastels (ink text on a pastel fill — NO green anywhere) ─────────────
PASTELS = ["#a8d4f0", "#aee5c2", "#f3c5a3", "#f2ddb0", "#d9c5f0", "#f0b8b8", "#b8e0e8"]

def pastel_for(key):
    """Deterministic pastel from a string key (stable across runs)."""
    h = 0
    for ch in key:
        h = (h * 31 + ord(ch)) & 0xFFFFFFFF
    return PASTELS[h % len(PASTELS)]

# ── icon library — inline SVG bodies (recolored to currentColor) ─────────────
# For custom/experimental toolkits with no real brand logo, we render a tasteful
# icon from the in-repo library instead of an ugly monogram tile.
ICON_LIB = {
    # /web/toolkit-icon.svg
    "toolkit": '<svg viewBox="0 0 403 403" fill="currentColor" xmlns="http://www.w3.org/2000/svg"><path d="M236.488 385.511C228.089 384.055 215.178 380.149 206.549 377.84L152.046 363.239L106.616 351.057C98.244 348.811 89.656 346.903 81.5422 343.9C60.8347 336.235 58.051 316.967 53.2469 298.52L43.8095 263.146C38.3903 243.522 33.121 223.857 28.0013 204.152C25.1197 193.454 22.0391 182.806 19.4602 172.032C13.8179 148.492 27.2826 137.174 42.3391 122.246C50.3665 114.345 58.3355 106.386 66.2444 98.3739L112.914 51.7801C121.087 43.5938 129.517 34.6708 137.964 26.8447C145.986 19.4138 157.153 16.6864 168.004 17.5065C176.179 18.7436 190.053 22.8767 198.362 25.1029L252.165 39.5247L297.88 51.7788C312.971 55.8179 329.762 58.1276 339.685 71.1678C347.33 81.2183 349.436 95.2271 352.574 107.282L362.399 143.595C370.349 172.763 378.054 202.088 385.791 231.314C386.8 235.13 387.049 241.167 386.59 245.089C385.79 251.979 383.138 258.522 378.917 264.026C374.53 269.823 359.772 283.927 354.018 289.606L316.077 327.62L283.639 359.955C269.457 374.222 259.068 388.38 236.488 385.511ZM202.198 330.78C208.537 332.478 216.386 334.789 222.701 335.993C246.887 339.223 255.702 325.117 271.331 309.444L304.251 276.443C308.445 272.17 312.688 267.944 316.977 263.766C323.917 257.028 333.512 248.603 325.794 238.303C320.64 231.428 301.084 227.998 292.548 225.724L239.394 211.542C221.717 206.814 203.937 204.387 197.868 184.008C190.333 158.705 184.438 132.877 177.14 107.503C175.13 100.513 172.916 87.8214 169.485 81.8156C156.309 67.5475 145.808 81.5015 136.395 91.0129L94.3827 133.273C87.3023 140.386 79.046 147.222 73.246 155.377C61.886 171.346 70.0236 189.049 74.5302 205.929C78.3584 220.747 82.3067 235.531 86.3795 250.282C90.1574 264.061 93.6342 284.179 101.393 296.072C108.382 306.779 125.158 310.12 136.962 313.292L167.763 321.545L202.198 330.78Z"/></svg>',
    # /web/nexus-icon.svg
    "nexus": '<svg viewBox="0 0 403 403" fill="currentColor" xmlns="http://www.w3.org/2000/svg"><path d="M372.841 231.087C368.142 237.284 355.136 245.711 348.251 249.221C309.23 269.113 264.188 275.313 220.934 277.441C213.023 277.821 205.101 277.923 197.182 277.744C192.013 277.668 186.474 277.167 181.346 277.864C179.178 278.159 176.991 278.893 175.121 280.031C171.719 282.103 169.261 285.641 168.367 289.51C165.734 300.906 179.191 329.215 185.361 339.025C188.944 344.727 194.128 352.252 201.091 353.77C203.876 354.378 206.469 353.661 208.812 352.12C223.947 342.166 234.753 308.958 238.349 291.689C246.323 291.048 263.054 289.695 270.643 287.942C269.729 293.198 267.974 299.734 266.623 304.959C260.562 327.893 252.352 350.645 236.326 368.569C219.189 387.737 194.325 391.024 174.63 373.048C157.412 357.336 148.795 337.73 141.841 316.012C137.176 301.451 135.586 286.643 122.822 276.504C112.309 267.695 102.588 266.912 89.9585 263.11C70.4228 257.228 50.3411 248.851 35.1557 234.917C26.1974 226.698 19.0139 215.063 18.6391 202.68C18.27 190.483 23.5331 180.649 31.5842 172.022C34.2717 169.25 37.6844 165.73 40.7459 163.376C56.9037 150.944 76.887 143.599 96.3612 138.152C102.405 136.461 109.376 135.161 115.023 133.395C113.587 144.174 112.46 154.995 111.641 165.841C93.757 169.341 65.354 180.045 52.8539 193.738C50.9016 195.84 49.2501 199.263 49.6056 202.262C50.64 210.46 62.2666 218.34 69.6149 222.081C81.3551 227.544 99.2836 236.348 112.4 236.041C129.42 235.642 125.879 213.612 125.71 203.119C125.666 197.012 125.74 190.906 125.93 184.803C127.352 139.839 135.755 75.2879 164.623 38.3603C172.455 28.3383 184.76 18.8599 197.938 18.0096C232.217 15.8014 250.273 52.7129 260.046 79.5054C261.898 84.4889 263.519 89.5551 264.905 94.6869C268.628 108.213 270.336 116.267 281.459 126.161C292.037 135.57 304.17 136.169 316.882 140.335C335.007 146.507 352.686 153.112 367.33 165.921C389.45 185.27 391.976 208.659 372.841 231.087ZM329.666 224.254C336.05 221.325 346.734 214.883 351.108 209.328C357.925 200.625 354.522 194.018 346.048 187.955C333.064 178.668 314.122 169.805 298.372 166.985C275.596 162.907 278.31 184.714 278.552 198.24C278.718 207.042 278.583 215.847 278.145 224.639C266.993 226.928 258.015 227.77 247.306 229.574C247.689 222.519 247.931 215.457 248.029 208.392C248.151 193.15 247.271 181.946 236.538 169.979C228.848 161.406 216.935 155.806 205.466 155.556C195.669 155.342 183.479 155.635 173.685 156.406C174.84 146.05 176.409 135.745 178.387 125.517C187.276 125.117 196.173 124.908 205.071 124.89C208.003 124.896 211.66 124.953 214.55 125.107C246.516 126.811 235.484 100.032 228.763 83.0904C224.865 74.1023 211.374 42.6881 197.309 49.6087C186.291 55.0313 176.875 76.2376 172.918 87.4522C169.376 97.3315 166.505 107.44 164.324 117.709C159.525 140.892 156.9 164.479 156.487 188.163C156.324 194.558 155.999 203.498 156.851 209.67C157.434 213.923 158.689 218.058 160.571 221.919C165.476 232.188 174.408 240.504 185.147 244.434C195.959 248.391 210.581 247.336 222.153 246.748C258.39 244.907 296.458 239.491 329.666 224.254Z"/></svg>',
    # /web/browser-icon.svg
    "browser": '<svg viewBox="0 0 403 403" fill="currentColor" xmlns="http://www.w3.org/2000/svg"><path d="M255.494 117.666C250.42 117.679 245.915 123.002 246.758 127.857C247.523 132.264 251.146 138.332 252.975 142.698C256.703 151.729 259.076 161.265 260.017 170.994C262.941 198.91 254.431 226.819 236.441 248.319C218.911 269.373 193.757 282.582 166.519 285.036C139.163 287.575 111.929 279.085 90.8255 261.443C70.8224 244.823 57.8239 221.229 54.4348 195.401C53.4682 187.996 56.7846 165.626 43.6931 166.928C39.8349 167.312 34.3063 172.804 31.4914 175.813C19.0714 189.097 5.63616 199.732 8.35394 219.793C8.83925 223.606 10.0121 227.302 11.8158 230.693C19.0066 244.072 41.4283 263.568 53.5653 272.878C81.7339 293.389 114.092 307.376 148.303 313.83C230.054 329.768 320.621 306.398 376.413 242.421C379.35 239.054 382.335 235.634 384.585 231.752C386.405 228.633 387.668 225.221 388.318 221.663C391.628 203.884 382.414 193.566 371.006 181.484C341.848 150.605 297.396 125.274 255.494 117.666Z"/><path d="M140.399 52.7404C133.98 52.161 131.591 54.9901 128.516 60.3889C124.479 67.4708 120.724 73.5094 113.383 77.6257C104.327 82.7018 94.8418 79.902 85.2957 81.8355C83.216 82.2584 80.5532 84.4703 79.7866 86.4528C75.8066 96.0025 87.9136 100.061 94.0956 104.115C96.9867 106.039 99.5965 108.349 101.843 110.98C113.384 124.617 101.811 143.238 114.945 148.485C124.663 150.098 126.518 140.572 131.281 134.009C134.27 129.883 137.055 126.567 141.52 124.03C148.395 118.108 164.825 122.076 170.383 119.354C186.943 111.247 167.936 100.496 161.885 97.3807C153.493 92.2724 149.525 85.4935 147.967 76.1856C146.405 66.8198 151.005 56.8644 140.399 52.7404Z"/></svg>',
    # /web/wb-file-icon.svg
    "wb-file": '<svg viewBox="0 0 403 403" fill="currentColor" xmlns="http://www.w3.org/2000/svg"><path d="M402.535 170.145C402.928 175.931 402.506 183.894 400.66 189.408C397.139 199.921 392.439 210.441 388.527 220.782L366.162 278.923C360.991 292.03 354.71 307.368 350.03 320.372C340.732 347.609 324.555 368.427 297.902 380.395C278.045 389.315 262.642 388.348 241.505 388.338L198.21 388.32L147.394 388.334C138.954 388.334 127.501 388.66 119.216 388.084C113.711 387.689 108.288 386.532 103.099 384.648C89.8822 379.761 77.8807 367.927 72.0805 355.129C67.4025 344.815 66.4171 331.996 68.3939 320.918C69.8629 312.705 73.1203 306.235 76.1303 298.657L84.6068 276.87L107.29 217.858C111.944 205.904 116.725 193.421 121.523 181.783C132.039 156.281 132.172 131.063 120.551 105.92C118.807 102.146 112.599 91.348 109.768 88.5105C107.836 86.5738 105.485 85.1079 102.894 84.2282C95.2782 81.6552 85.9355 84.715 82.143 91.9987C79.792 96.5109 78.3818 101.292 76.5766 106.031L68.0336 128.133C62.9438 141.608 56.7244 155.836 51.8852 169.381C48.7826 178.666 44.2453 188.504 40.851 198.013C35.2258 213.774 23.6568 231.34 38.4389 246.29C45.6702 253.603 53.8932 254.349 63.4994 254.18C60.0605 264.47 55.8665 274.127 51.9643 284.224C30.5824 281.012 16.552 272.617 6.37929 253.016C-7.3112 226.63 5.28091 205.804 14.7123 181.27L41.0707 113.475C42.5808 109.656 43.7862 105.434 45.4096 101.711C51.8276 86.9725 56.255 70.359 64.8559 56.737C79.4218 33.6687 104.504 17.4868 131.727 14.7312C141.649 13.727 151.42 13.9919 161.373 13.9929L205.293 14.0046L255.73 13.9968C264.163 13.9958 275.78 13.6555 283.879 14.2468C289.12 14.6109 294.289 15.6795 299.246 17.4216C312.898 22.2688 325.031 33.8902 330.88 46.7917C339.41 65.6051 335.862 84.9637 327.331 102.899C325.334 107.099 323.409 113.267 321.763 117.772C344.253 117.304 365.448 115.777 383.182 131.467C394.799 141.744 401.166 154.902 402.535 170.145ZM269.938 346.397C270.947 344.067 271.009 340.566 270.782 337.978C269.826 333.352 267.773 330.846 265.287 326.965C258.322 316.088 249.332 306.637 238.513 299.491C213.043 282.67 190.135 284.609 161.529 284.616L114.231 284.636C110.837 293.323 107.229 301.896 104.072 310.655C100.049 321.452 94.5616 330.905 99.9672 342.601C103.945 351.212 112.817 358.049 122.543 357.977C129.854 358.053 136.989 358.063 144.224 358.066L184.201 358.073L229.139 358.073C236.946 358.073 244.6 357.991 252.63 358.022C261.056 358.06 266.551 354.212 269.938 346.397ZM304.093 78.6941C305.015 75.7078 305.432 72.5881 305.328 69.4646C305.289 68.1075 305.197 66.7526 305.05 65.4031C302.6 54.5516 293.459 45.036 282.108 44.4489C273.879 44.023 265.092 44.2557 256.822 44.2595L209.099 44.2839L168.528 44.2595C160.559 44.2561 151.917 43.7804 144.116 45.0114C140.955 45.5105 135.391 51.0983 133.959 53.9597C129.484 62.908 133.97 69.475 138.648 76.5691C148.278 91.1709 161.187 102.325 177.039 109.682C196.736 118.926 217.847 117.759 238.995 117.742C243.791 117.738 255.496 118.031 259.86 117.462C256.498 123.717 254.563 130.388 252.022 137.006C250.57 140.786 248.856 144.476 247.455 148.236C229.086 147.856 213.761 147.554 196.561 154.993C190.768 157.497 187.713 158.411 182.174 162.208C151.134 182.297 146.322 201.964 133.479 234.579C131.306 240.094 128.431 249.537 125.579 254.294C147.28 253.679 170.467 255.924 191.949 252.073C197.512 251.078 203.096 248.655 208.354 246.616C227.567 238.77 244.092 223.634 254.032 205.465C258.952 196.524 261.792 187.369 265.486 177.976L282.847 133.187C289.429 115.931 298.648 96.069 304.093 78.6941ZM362.464 203.848C366 193.854 372.23 183.598 371.64 172.613C371.092 165.035 369.201 159.966 363.492 154.719C354.622 146.569 343.363 148.067 332.06 148.098L309.604 148.138C306.549 156.794 303.703 163.642 300.456 172.031L287.073 206.999C281.87 220.569 275.885 233.076 274.241 247.958C272.512 263.608 274.724 274.931 279.786 289.486C282.854 297.926 290.445 313.679 298.822 317.519C303.121 319.503 308.053 319.613 312.435 317.818C322.074 313.919 323.265 304.515 326.728 295.718L353.141 227.76C356.246 219.722 359.562 212.051 362.464 203.848Z"/></svg>',
    # /web/learn/icons/org.svg
    "org": '<svg viewBox="0 0 256 256" fill="currentColor" xmlns="http://www.w3.org/2000/svg"><path d="M218.29,182.17a12,12,0,0,1-16.47,4.12L140,149.19V216a12,12,0,0,1-24,0V149.19l-61.82,37.1a12,12,0,1,1-12.35-20.58L104.68,128,41.83,90.29A12,12,0,1,1,54.18,69.71L116,106.81V40a12,12,0,0,1,24,0v66.81l61.82-37.1a12,12,0,1,1,12.35,20.58L151.32,128l62.85,37.71A12,12,0,0,1,218.29,182.17Z"/></svg>',
    # /web/learn/icons/wbx.svg
    "wbx": '<svg viewBox="0 0 256 256" fill="currentColor" xmlns="http://www.w3.org/2000/svg"><path d="M72.5,150.63,100.79,128,72.5,105.37a12,12,0,1,1,15-18.74l40,32a12,12,0,0,1,0,18.74l-40,32a12,12,0,0,1-15-18.74ZM144,172h32a12,12,0,0,0,0-24H144a12,12,0,0,0,0,24ZM236,56V200a20,20,0,0,1-20,20H40a20,20,0,0,1-20-20V56A20,20,0,0,1,40,36H216A20,20,0,0,1,236,56Zm-24,4H44V196H212Z"/></svg>',
    # /web/learn/icons/workflows.svg
    "workflows": '<svg viewBox="0 0 403 403" fill="currentColor" xmlns="http://www.w3.org/2000/svg"><path d="M23.4811 223.388C22.7054 213.189 25.339 203.02 30.9681 194.48C44.5292 174.34 81.6453 160.649 105.376 155.578C125.934 151.186 169.047 149.096 175.033 177.422C179.393 198.053 139.22 209.571 130.511 224.908C127.02 231.055 124.582 235.376 126.096 242.975C128.362 257.377 143.781 271.299 155.638 279.198C180.628 295.848 220.184 312.519 250.753 308.46C255.483 307.787 262.713 304.992 265.199 300.57C274.28 283.341 260.05 256.087 251.774 240.727C222.942 187.219 177.378 143.241 127.419 109.411C121.535 105.428 114.17 101.383 108.116 97.5287C81.1947 80.3898 65.2134 50.2718 84.2971 20.9C90.7645 10.9951 102.146 4.66043 113.887 2.74142C127.142 0.574174 139.411 3.78208 150.429 11.5822C160.04 19.4254 162.609 26.3686 167.726 37.3581C170.99 44.4336 174.345 51.4667 177.791 58.4548C188.325 79.8451 199.686 100.819 211.848 121.328C242.655 173.271 278.399 222.122 318.585 267.202C333.038 283.459 349.473 300.553 365.094 315.823C404.647 354.006 359.967 418.985 310.353 396.066C299.035 390.838 286.916 379.789 276.388 372.533C255.858 358.254 234.633 345 212.793 332.82C187.74 318.903 161.882 306.489 135.356 295.642C117.781 288.439 99.9256 281.942 81.8325 276.164C68.6132 271.913 51.0906 268.775 40.4348 259.658C29.6611 250.44 24.4564 237.403 23.4811 223.388Z"/><path d="M238.744 122.004C238.485 118.566 239.159 114.312 240.252 111.063C241.564 107.123 243.657 103.487 246.405 100.374C249.127 97.2965 254.174 93.2232 257.468 90.3375C262.991 85.5433 268.342 80.5548 273.512 75.3816C278.668 70.1783 283.654 64.8099 288.462 59.2839C292.501 54.6114 297.437 48.4567 301.883 44.3781C305.695 40.8723 309.993 37.9341 314.643 35.6542C324.806 30.6806 336.535 29.9755 347.221 33.6965C361.156 38.5327 370.243 48.2548 376.582 61.2329C378.043 64.8905 379.042 68.7161 379.557 72.621C381.304 85.1829 377.848 97.9133 369.989 107.868C365.325 113.867 359.357 118.725 352.536 122.074C345.945 125.26 335.343 127.429 327.943 129.291C321.184 131.03 314.465 132.923 307.793 134.97C305.358 135.703 303.05 136.527 300.636 137.32C284.293 142.688 265.604 156.44 249.384 143.068C242.298 137.227 239.673 130.695 238.744 122.004Z"/></svg>',
    # /web/learn/icons/vfs.svg
    "vfs": '<svg viewBox="0 0 256 256" fill="currentColor" xmlns="http://www.w3.org/2000/svg"><path d="M208,36H48A20,20,0,0,0,28,56V200a20,20,0,0,0,20,20H208a20,20,0,0,0,20-20V56A20,20,0,0,0,208,36Zm-4,24v56H52V60ZM52,196V140H204v56ZM160,88a16,16,0,1,1,16,16A16,16,0,0,1,160,88Zm32,80a16,16,0,1,1-16-16A16,16,0,0,1,192,168Z"/></svg>',
    # /web/learn/icons/autopoet.svg
    "autopoet": '<svg viewBox="0 0 256 256" fill="currentColor" xmlns="http://www.w3.org/2000/svg"><path d="M215.64,128a44,44,0,0,0-43.82-75.9,44,44,0,0,0-87.64,0A44,44,0,0,0,40.36,128a44,44,0,0,0,43.82,75.89,44,44,0,0,0,87.64,0A44,44,0,0,0,215.64,128ZM108,128a20,20,0,1,1,20,20A20,20,0,0,1,108,128Zm72.35-53.32a20,20,0,1,1,20,34.64c-2.65,1.53-10.52,4.88-30.1,6.42a44.08,44.08,0,0,0-10.52-18.18C170.86,81.36,177.7,76.21,180.35,74.68ZM128,36a20,20,0,0,1,20,20c0,3.06-1,11.55-9.49,29.28a43.79,43.79,0,0,0-21,0C109,67.55,108,59.06,108,56A20,20,0,0,1,128,36ZM48.33,82a20,20,0,0,1,27.32-7.32c2.65,1.53,9.49,6.68,20.62,22.88a44.08,44.08,0,0,0-10.52,18.18c-19.58-1.54-27.45-4.89-30.1-6.42A20,20,0,0,1,48.33,82Zm27.32,99.32a20,20,0,1,1-20-34.64c2.65-1.53,10.52-4.88,30.1-6.42a44.08,44.08,0,0,0,10.52,18.18C85.14,174.64,78.3,179.79,75.65,181.32ZM128,220a20,20,0,0,1-20-20c0-3.06,1-11.55,9.49-29.28a43.79,43.79,0,0,0,21,0C147,188.45,148,196.94,148,200A20,20,0,0,1,128,220Zm79.67-46a20,20,0,0,1-27.32,7.32c-2.65-1.53-9.49-6.68-20.62-22.88a44.08,44.08,0,0,0,10.52-18.18c19.58,1.54,27.45,4.89,30.1,6.42A20,20,0,0,1,207.67,174Z"/></svg>',
    # /web/learn/icons/agents.svg
    "agents": '<svg viewBox="0 0 403 403" fill="currentColor" xmlns="http://www.w3.org/2000/svg"><path d="M258.418 8.45507L258.604 8.36136C273.275 0.999295 286.552 9.15111 292.954 23.2084C294.258 26.0671 295.117 29.2608 296.646 31.977C297.018 32.6397 302.31 32.0284 303.286 31.9191C316.093 30.1615 329.072 30.7422 341.343 35.0424C358.93 40.9196 377.068 55.7734 385.367 72.5817C391.556 86.3951 396.151 104.326 392.404 119.303C390.946 125.133 384.533 130.422 381.977 121.654C380.742 118.246 380.891 114.545 380.023 111.077C376.662 97.6399 366.336 82.4841 353.81 76.2036C346.577 72.5754 347.277 77.7255 348.607 82.9174C354.138 104.683 354.827 130.966 346.825 152.316C333.494 187.89 306.844 219.402 286.307 251.141C281.297 258.801 276.542 266.628 272.052 274.604C268.49 281.035 265.498 287.938 261.122 293.905C258.469 297.576 252.179 306.479 246.971 304.295C238.653 300.807 248.345 285.355 250.881 280.045C254.484 272.556 257.964 265.009 261.316 257.406C272.797 231.436 282.275 204.907 295.509 179.692C297.528 175.231 299.718 170.763 301.285 166.119C301.876 164.366 302.717 161.734 300.708 160.798C293.756 161.251 262.454 197.677 256.427 204.984C252.303 209.984 246.84 218.876 241.723 222.292C240.312 223.235 238.624 224.017 236.893 223.596C235.584 223.277 234.593 222.364 233.929 221.219C231.345 216.754 233.221 209.344 234.359 204.546C236.582 195.178 239.727 186.428 244.769 178.192C250.198 169.319 257.335 161.451 264.618 154.076C275.201 143.361 300.508 123.062 304.065 109.458C305.506 103.953 304.042 98.4475 301.16 93.662C299.168 90.3539 296.223 87.7577 292.4 86.8807C271.512 82.0868 221.379 128.325 205.369 140.827C198.075 146.522 190.104 151.539 182.223 156.38C162.332 169.039 139.741 183.601 123.554 201.017C116.647 208.448 108.9 220.006 109.464 230.401C109.97 239.722 121.539 233.369 126.026 231.341C147.434 219.883 181.055 213.668 180.632 248.873C180.036 265.403 173.053 281.295 165.56 295.795C162.839 301.061 153.301 319.602 146.922 319.943C138.022 320.422 146.169 299.485 147.495 295.102C148.407 292.05 149.203 288.963 149.881 285.848C156.158 257.413 150.067 245.038 123.932 267.946C105.138 284.42 97.8672 301.998 94.8423 326.357C94.1244 332.419 93.6657 338.51 93.4667 344.612C93.2717 351.541 94.9379 376.443 91.4332 380.669C90.6821 381.573 89.5177 381.97 88.3791 382.059C86.1803 382.23 84.3433 381.561 82.6769 380.118C80.242 378.009 78.546 374.979 76.9975 372.191C64.9684 350.537 62.913 318.8 61.1555 294.211C58.6751 259.514 59.1372 221.19 77.6621 190.525C82.126 183.136 87.6698 176.762 93.3023 170.259C90.1319 161.829 83.9078 155.036 86.5983 145.386C88.1375 139.866 92.2948 135.569 97.2309 132.863C103.494 129.429 112.073 127.978 118.996 130.056C122.73 131.177 126.136 133.498 127.961 137.017C129.32 139.64 129.636 142.652 129.213 145.548C127.288 158.741 112.692 163.686 111.872 167.141C111.759 167.619 111.925 167.664 112.172 168.051C117.068 170.275 135.768 160.755 141.066 158.302C152.466 153.083 163.673 147.454 174.665 141.425C180.712 138.112 186.778 134.753 192.475 130.842C202.103 124.249 210.283 116.062 218.691 108.095C235.013 92.6299 251.264 77.071 266.844 60.8577C269.374 58.2244 280.783 47.2195 280.583 44.0547C279.071 42.4024 275.763 43.7194 273.756 44.0818C250.19 48.3361 235.327 22.5015 258.418 8.45507Z"/></svg>',
}

# slug → icon-library key, for toolkits that have no real brand logo
SLUG_ICON = {
    "byod": "nexus", "ctk": "toolkit", "docs": "wb-file", "glyphs": "wbx",
    "icons": "toolkit", "mono": "wb-file", "orgitorial": "org",
    "palette": "wbx", "presentation": "workflows", "publish": "workflows",
    "sandbox": "vfs", "toolkit-forge": "toolkit", "video": "browser",
    "wavelet": "org", "workbooks-system": "autopoet", "wraith": "browser",
}

# ── Lucide (standard icon library) — generic icons by CATEGORY ───────────────
# Logo-less toolkits get a standard Lucide icon chosen by category. Our CUSTOM
# brand glyphs (petal/workbook/nexus…) are reserved for toolkits that ARE that
# noun — see NOUN_GLYPH below — never used as generic category fillers.
_LSTROKE = 'fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"'
LUCIDE = {
    "Dev tools":   '<path d="M12 19h8"/><path d="m4 17 6-6-6-6"/>',
    "Media":       '<rect width="18" height="18" x="3" y="3" rx="2"/><path d="M7 3v18"/><path d="M3 7.5h4"/><path d="M3 12h18"/><path d="M3 16.5h4"/><path d="M17 3v18"/><path d="M17 7.5h4"/><path d="M17 16.5h4"/>',
    "Design":      '<path d="M12 22a1 1 0 0 1 0-20 10 9 0 0 1 10 9 5 5 0 0 1-5 5h-2.25a1.75 1.75 0 0 0-1.4 2.8l.3.4a1.75 1.75 0 0 1-1.4 2.8z"/><circle cx="13.5" cy="6.5" r=".5" fill="currentColor"/><circle cx="17.5" cy="10.5" r=".5" fill="currentColor"/><circle cx="6.5" cy="12.5" r=".5" fill="currentColor"/><circle cx="8.5" cy="7.5" r=".5" fill="currentColor"/>',
    "Deploy":      '<path d="M12 13v8"/><path d="M4 14.899A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.5 8.242"/><path d="m8 17 4-4 4 4"/>',
    "Integration": '<path d="M10 22V7a1 1 0 0 0-1-1H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-5a1 1 0 0 0-1-1H2"/><rect x="14" y="2" width="8" height="8" rx="1"/>',
    "Pipeline":    '<path d="M15 6a9 9 0 0 0-9 9V3"/><circle cx="18" cy="6" r="3"/><circle cx="6" cy="18" r="3"/>',
    "System":      '<path d="M12 20v2"/><path d="M12 2v2"/><path d="M17 20v2"/><path d="M17 2v2"/><path d="M2 12h2"/><path d="M2 17h2"/><path d="M2 7h2"/><path d="M20 12h2"/><path d="M20 17h2"/><path d="M20 7h2"/><path d="M7 20v2"/><path d="M7 2v2"/><rect x="4" y="4" width="16" height="16" rx="2"/><rect x="8" y="8" width="8" height="8" rx="1"/>',
    "Assets":      '<rect width="18" height="18" x="3" y="3" rx="2" ry="2"/><circle cx="9" cy="9" r="2"/><path d="m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21"/>',
}
LUCIDE_DEFAULT = '<path d="M11 21.73a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73z"/><path d="M12 22V12"/><polyline points="3.29 7 12 12 20.71 7"/><path d="m7.5 4.27 9 5.15"/>'

# Toolkits that ARE a core Workbooks noun → keep the custom brand glyph.
NOUN_GLYPH = {"workbooks-system": "wb-file"}

def lucide_for(category):
    body = LUCIDE.get(category, LUCIDE_DEFAULT)
    return f'<svg viewBox="0 0 24 24" {_LSTROKE}>{body}</svg>'

# ── manifest parsing ────────────────────────────────────────────────────────

def read_headers(text):
    """Collect all `#+KEY: value` org keywords (last-wins, plus list for repeats)."""
    hdr = {}
    for m in re.finditer(r"^#\+([A-Z_]+):[ \t]*(.*)$", text, re.M):
        k, v = m.group(1), m.group(2).strip()
        hdr[k] = v
    return hdr


def first_prose(text):
    """The first real paragraph of body prose (skips headers, drawers, headings)."""
    lines = text.splitlines()
    buf, started = [], False
    for ln in lines:
        s = ln.strip()
        if s.startswith("#+") or s.startswith("* ") or s.startswith(":") or not s:
            if started and not s:
                break
            continue
        # skip property-drawer noise / heading stars
        if re.match(r"^\*+ ", s) or s.upper() == s and ":END:" in s:
            continue
        started = True
        buf.append(s)
        if len(buf) >= 3:
            break
    out = " ".join(buf)
    out = re.sub(r"=([^=]+)=", r"\1", out)        # org verbatim → plain
    out = re.sub(r"~([^~]+)~", r"\1", out)        # org code → plain
    out = re.sub(r"\s+", " ", out).strip()
    return out


# ── derivation: capabilities, integration, category ─────────────────────────

# external services we recognize (env-key prefix / name → display label)
INTEGRATIONS = {
    "asana": "Asana", "linear": "Linear", "brandnana": "Brandnana",
    "cloudflare": "Cloudflare", "wrangler": "Cloudflare", "railway": "Railway",
    "byod": "Postgres + Railway", "stripe": "Stripe", "slack": "Slack",
    "github": "GitHub", "fly": "Fly.io", "tauri": "Tauri", "capacitor": "Capacitor",
}

# slug → category bucket (marketplace facet). Falls back to KIND-based mapping.
KIND_CATEGORY = {
    "federation": "Integration",
    "render": "Rendering",
    "knowledge+assets": "Assets",
    "knowledge+pipeline": "Pipeline",
    "toolkit": "Capability",
}
SLUG_CATEGORY = {
    "ffmpeg": "Media", "video": "Media", "image": "Media",
    "git": "Dev tools", "toolkit-forge": "Dev tools", "sandbox": "Dev tools",
    "ctk": "Dev tools",
    "cloudflare": "Deploy", "wrangler": "Deploy", "railway": "Deploy",
    "byod": "Deploy", "publish": "Deploy", "tauri": "Deploy", "capacitor": "Deploy",
    "asana": "Integration", "linear": "Integration", "brandnana": "Integration",
    "3w": "Research", "docs": "Pipeline", "orgitorial": "Pipeline",
    "glyphs": "Assets", "icons": "Assets", "open-avatars": "Assets",
    "palette": "Design", "mono": "Design", "wavelet": "Design",
    "presentation": "Design",
    "wraith": "Dev tools", "workbooks-system": "System",
}

CAP_RULES = [
    # (regex over the manifest text, capability label)
    (r"\bsearch\b|web search|deep.?research", "web-search"),
    (r"\bfetch\b|\bread\b.*url|readability|render", "fetch"),
    (r"\bvideo\b|ffmpeg|transcode|h264|gif", "video"),
    (r"\baudio\b|\bmp3\b|\bwav\b", "audio"),
    (r"\bimage\b|\bresize\b|\bcrop\b|montage|overlay", "image"),
    (r"\bpalette\b|design token|type scale", "design-tokens"),
    (r"\bfont\b|typeface|wavelet|\bmono\b", "fonts"),
    (r"\blogo\b|icon|svg|glyph|avatar", "assets"),
    (r"\bD1\b|postgres|sqlite|\bdatabase\b|data.?source", "database"),
    (r"\bdeploy\b|wrangler|railway|fly\.io|pages|hosting", "deploy"),
    (r"\bauth\b|betterauth|session|jwt|oauth", "auth"),
    (r"\bgit\b|version control|rebase|commit", "git"),
    (r"\bdesktop\b|tauri", "desktop"),
    (r"\bmobile\b|capacitor|ios|android", "mobile"),
    (r"\bsandbox\b|wasm|isolat", "sandbox"),
    (r"\bagent\b|\bai\b|workers ai|vision", "ai"),
    (r"task|federation|issues|project", "tasks"),
    (r"\bdocs?\b|documentation|diátaxis|diataxis", "docs"),
    (r"\bbrand\b|\bad\b|creative|catalog|social", "brand"),
    (r"presentation|slides|deck", "slides"),
]


def derive_caps(text, hdr):
    caps = []
    # explicit #+CAPS: wins, comma/space separated
    if hdr.get("CAPS"):
        caps = [c.strip() for c in re.split(r"[,\s]+", hdr["CAPS"]) if c.strip()]
    low = text.lower()
    for rx, label in CAP_RULES:
        if label in caps:
            continue
        if re.search(rx, low):
            caps.append(label)
    return caps[:8]


def derive_integration(slug, hdr):
    if slug in INTEGRATIONS:
        return INTEGRATIONS[slug]
    env = (hdr.get("ENV_KEYS") or "").lower()
    for key, label in INTEGRATIONS.items():
        if key in env:
            return label
    return None


def derive_category(slug, hdr):
    if slug in SLUG_CATEGORY:
        return SLUG_CATEGORY[slug]
    return KIND_CATEGORY.get((hdr.get("KIND") or "").strip(), "Capability")


def maturity(status):
    s = (status or "").lower()
    return {
        "stable": ("Stable", "stable"),
        "beta": ("Beta", "beta"),
        "experimental": ("Experimental", "exp"),
        "exp": ("Experimental", "exp"),
        "partial": ("Partial", "exp"),
    }.get(s, ("Experimental", "exp"))


# ── catalog build ───────────────────────────────────────────────────────────

def load_releases():
    try:
        with open(RELEASES) as f:
            return json.load(f)
    except Exception:
        return {}


def build_catalog():
    releases = load_releases()
    items = []
    for name in sorted(os.listdir(TK_DIR)):
        if name in EXCLUDE:
            continue
        mpath = os.path.join(TK_DIR, name, "manifest.org")
        if not os.path.isfile(mpath):
            continue
        with open(mpath, encoding="utf-8") as f:
            text = f.read()
        hdr = read_headers(text)
        slug = (hdr.get("TOOLKIT") or name).strip()
        if slug in EXCLUDE:
            continue
        title = slug
        tagline = hdr.get("TAGLINE", "").strip()
        version = (hdr.get("VERSION") or releases.get(slug, {}).get("version") or "0.1.0").strip()
        kind = (hdr.get("KIND") or "toolkit").strip()
        status = (hdr.get("STATUS") or "experimental").strip()
        caps = derive_caps(text, hdr)
        integration = derive_integration(slug, hdr)
        category = derive_category(slug, hdr)
        logo = f"/toolkits/logos/{slug}.svg"
        logo_path = os.path.join(OUT_DIR, "logos", f"{slug}.svg")
        # a "real" brand logo is a fetched SVG; monogram-text tiles don't count
        real_logo = False
        if os.path.isfile(logo_path):
            try:
                with open(logo_path, encoding="utf-8") as lf:
                    real_logo = "<text" not in lf.read()
            except Exception:
                real_logo = False
        items.append({
            "slug": slug,
            "title": title,
            "tagline": tagline,
            "version": version,
            "kind": kind,
            "status": status,
            "caps": caps,
            "integration": integration,
            "category": category,
            "logo": logo,
            "real_logo": real_logo,
            "tint": pastel_for(slug),
            "cli_bin": (hdr.get("CLI_BIN") or "").strip() or None,
            "env_keys": [e for e in re.split(r"\s+", (hdr.get("ENV_KEYS") or "").strip()) if e],
            "requires": (hdr.get("REQUIRES") or "").strip() or None,
            "flow": (hdr.get("FLOW") or "").strip() or None,
            "env_note": (hdr.get("ENV_NOTE") or "").strip() or None,
            "description": first_prose(text),
            "updated": releases.get(slug, {}).get("updated"),
        })
    return items


# ── HTML shared chrome ──────────────────────────────────────────────────────

def head(title, desc, canonical, extra=""):
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<meta name="description" content="{html.escape(desc)}">
<link rel="canonical" href="{canonical}">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/fonts/fonts.css">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Workbooks">
<meta property="og:title" content="{html.escape(title)}">
<meta property="og:description" content="{html.escape(desc)}">
<meta property="og:url" content="{canonical}">
<meta property="og:image" content="https://workbooks.sh/og.jpg">
<meta name="twitter:card" content="summary_large_image">
{extra}
<style>
{BASE_CSS}
</style>
</head>"""


NAV = '<div id="site-nav"></div><script src="/nav.js?v=17"></script>'

BASE_CSS = """
@font-face{ font-family:"Franie"; src:url("/fonts/Franie-SemiBold.woff2") format("woff2"); font-weight:600; font-display:block; }
@font-face{ font-family:"Franie"; src:url("/fonts/Franie-SemiBoldItalic.woff2") format("woff2"); font-weight:600; font-style:italic; font-display:block; }
@font-face{ font-family:"Franie"; src:url("/fonts/Franie-Bold.woff2") format("woff2"); font-weight:700; font-display:block; }
:root{
  --paper:#f7f6f1; --card:#fff; --ink:#121316;
  --dim:#6a6f68; --line:rgba(18,19,22,.12);
  --p-blue:#a8d4f0; --p-mint:#aee5c2; --p-peach:#f3c5a3; --p-sand:#f2ddb0;
  --p-lav:#d9c5f0; --p-rose:#f0b8b8; --p-aqua:#b8e0e8;
  --display:"Franie",sans-serif;
  --mono:"JetBrains Mono",ui-monospace,monospace;
  --max:1180px;
}
*{ box-sizing:border-box; margin:0; }
html{ scrollbar-width:thin; scrollbar-color:#565b54 transparent; }
body{ background:var(--paper); color:var(--ink); font-family:var(--mono); line-height:1.65;
  -webkit-font-smoothing:antialiased; }
a{ color:inherit; }
.wrap{ max-width:var(--max); margin:0 auto; padding:0 28px; }

/* ── hero ── */
.hero{ max-width:var(--max); margin:0 auto; padding:154px 28px 46px; }
.hero .kick{ display:inline-flex; align-items:center; gap:9px; font:700 10.5px var(--mono);
  letter-spacing:.26em; text-transform:uppercase; color:var(--ink); background:var(--p-aqua);
  border:1.5px solid var(--ink); border-radius:999px; padding:7px 14px; margin-bottom:26px; }
.hero h1{ font-family:var(--display); font-weight:600; font-size:clamp(44px,7vw,96px);
  line-height:1.02; letter-spacing:-.015em; max-width:16ch; }
.hero h1 em{ font-style:italic; font-weight:600; }
.hero h1 .rot{ background:var(--rotc,var(--p-lav)); padding:0 .1em 0 .12em; border-radius:.07em;
  box-decoration-break:clone; -webkit-box-decoration-break:clone; transition:background .35s ease; white-space:nowrap; }
.hero h1 .rot::after{ content:""; display:inline-block; width:.055em; height:.74em; margin-left:.02em;
  background:var(--ink); vertical-align:-.02em; animation:caret 1.05s step-end infinite; }
.hero h1 .rot.norot::after{ display:none; }
@keyframes caret{ 0%,100%{ opacity:1; } 50%{ opacity:0; } }
.hero p{ margin-top:26px; max-width:60ch; font-size:14.5px; color:var(--dim); line-height:1.85; }
.hero code{ background:var(--card); border:1px solid var(--line); border-radius:5px;
  padding:.5px 6px; font-size:.92em; color:var(--ink); }
.stat{ margin-top:34px; display:flex; gap:14px; flex-wrap:wrap; }
.stat .badge{ display:flex; flex-direction:column; gap:2px; min-width:140px;
  background:var(--p-blue); border:2px solid var(--ink); border-radius:14px;
  box-shadow:4px 4px 0 var(--ink); padding:16px 20px; }
.stat .badge b{ font-family:var(--mono); font-weight:800; font-size:40px; line-height:1;
  letter-spacing:-.03em; color:var(--ink); }
.stat .badge span{ font:700 10.5px var(--mono); letter-spacing:.14em; text-transform:uppercase;
  color:var(--ink); opacity:.78; }
.stat .badge:nth-child(2){ background:var(--p-mint); }
.stat .badge:nth-child(3){ background:var(--p-peach); }

/* ── controls ── */
.controls{ position:sticky; top:0; z-index:5; background:var(--paper);
  border-bottom:2px solid var(--ink); padding:16px 0; }
.controls .wrap{ display:flex; gap:14px; align-items:center; flex-wrap:wrap; }
.count{ font:700 11px var(--mono); letter-spacing:.1em; text-transform:uppercase; color:var(--dim);
  margin-right:auto; white-space:nowrap; }
.search{ flex:0 1 380px; display:flex; align-items:center; gap:10px; background:var(--card);
  border:2px solid var(--ink); border-radius:10px; padding:10px 14px; box-shadow:3px 3px 0 var(--ink); }
.search svg{ width:16px; height:16px; flex:0 0 auto; color:var(--dim); }
.search input{ border:0; outline:0; background:none; font:500 13px var(--mono); color:var(--ink);
  width:100%; }
.search input::placeholder{ color:var(--dim); }
.catsel{ font:700 10.5px var(--mono); letter-spacing:.06em; text-transform:uppercase;
  border:2px solid var(--ink); background:var(--card); color:var(--ink); border-radius:10px;
  padding:11px 32px 11px 14px; cursor:pointer; box-shadow:3px 3px 0 var(--ink);
  appearance:none; -webkit-appearance:none;
  background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='10' height='10' viewBox='0 0 24 24' fill='none' stroke='%23121316' stroke-width='3' stroke-linecap='round'%3E%3Cpath d='M6 9l6 6 6-6'/%3E%3C/svg%3E");
  background-repeat:no-repeat; background-position:right 12px center; }

/* ── grid ── */
.grid{ display:grid; grid-template-columns:repeat(auto-fill,minmax(290px,1fr)); gap:18px;
  padding:34px 0 96px; }
.card{ display:flex; flex-direction:column; background:var(--card); border:2px solid var(--ink);
  border-radius:16px; padding:22px; text-decoration:none; box-shadow:4px 4px 0 var(--ink);
  transition:transform .14s ease, box-shadow .14s ease; }
.card:hover{ transform:translate(-3px,-3px); box-shadow:8px 8px 0 var(--ink); }
.card .top{ display:flex; align-items:flex-start; gap:14px; margin-bottom:15px; }
.logo{ width:50px; height:50px; border-radius:13px; flex:0 0 auto; display:flex;
  align-items:center; justify-content:center; overflow:hidden; border:2px solid var(--ink); }
.logo img{ width:30px; height:30px; object-fit:contain; }
.logo svg{ width:26px; height:26px; color:var(--ink); display:block; }
.logo.brand{ background:#fff !important; }
.card .hd{ min-width:0; }
.card h3{ font-family:var(--display); font-weight:600; font-size:23px; line-height:1.05;
  letter-spacing:-.01em; overflow-wrap:anywhere; }
.card .ver{ font:700 9.5px var(--mono); letter-spacing:.05em; color:var(--dim); margin-top:6px; }
.card .tag{ font-size:12.5px; color:var(--dim); line-height:1.65; flex:1;
  display:-webkit-box; -webkit-line-clamp:3; -webkit-box-orient:vertical; overflow:hidden; }
.card .meta{ display:flex; gap:7px; flex-wrap:wrap; margin-top:16px; align-items:center; }
.cc{ font:700 9px var(--mono); letter-spacing:.05em; text-transform:uppercase; color:var(--ink);
  background:var(--paper); border:1px solid var(--line); border-radius:6px; padding:4px 8px; }
.cc.cat{ background:var(--p-sand); border:1.5px solid var(--ink); }
.badge-m{ font:700 9px var(--mono); letter-spacing:.06em; text-transform:uppercase;
  padding:4px 9px; border-radius:6px; border:1.5px solid var(--ink); margin-left:auto; }
.m-stable{ background:var(--p-mint); } .m-beta{ background:var(--p-blue); }
.m-exp{ background:var(--card); color:var(--dim); }
.empty{ padding:70px 0; text-align:center; color:var(--dim); font-size:13px; }

/* ── detail ── */
.detail{ max-width:1080px; margin:0 auto; padding:150px 28px 90px; }
.crumb{ font:700 11px var(--mono); letter-spacing:.06em; text-transform:uppercase; color:var(--dim);
  margin-bottom:26px; }
.crumb a{ text-decoration:none; color:var(--dim); }
.crumb a:hover{ color:var(--ink); }
.dhead{ display:flex; gap:24px; align-items:flex-start; flex-wrap:wrap; }
.dhead .logo{ width:84px; height:84px; border-radius:20px; }
.dhead .logo img{ width:52px; height:52px; }
.dhead .logo svg{ width:44px; height:44px; }
.dhead h1{ font-family:var(--display); font-weight:600; font-size:clamp(38px,5vw,62px);
  line-height:1; letter-spacing:-.012em; }
.dhead .meta{ display:flex; gap:10px; align-items:center; margin-top:14px; flex-wrap:wrap; }
.dhead .lede{ margin-top:18px; font-size:15px; line-height:1.8; color:var(--ink); max-width:70ch; }
.cols{ display:grid; grid-template-columns:1fr 320px; gap:48px; margin-top:48px; align-items:start; }
.sec{ margin-bottom:42px; }
.sec h2{ font-family:var(--display); font-weight:600; font-size:27px; line-height:1.1;
  letter-spacing:-.01em; margin-bottom:16px; }
.sec p{ font-size:14px; line-height:1.85; color:var(--ink); margin-bottom:14px; }
.sec .dim{ color:var(--dim); }
.sec code{ background:var(--card); border:1px solid var(--line); border-radius:5px;
  padding:1px 6px; font-size:.92em; }
.caplist{ display:flex; gap:9px; flex-wrap:wrap; }
.caplist .cc{ font-size:11px; padding:7px 11px; background:var(--p-aqua); border:1.5px solid var(--ink); }
.install{ background:var(--ink); color:var(--paper); border-radius:12px; padding:18px 20px;
  font:500 13px var(--mono); display:flex; align-items:center; justify-content:space-between; gap:14px; }
.install code{ color:var(--p-mint); background:none; border:0; padding:0; }
.install button{ font:700 10px var(--mono); letter-spacing:.06em; text-transform:uppercase;
  background:var(--paper); color:var(--ink); border:0; border-radius:7px; padding:8px 12px; cursor:pointer; }
.detail a.docs{ color:var(--ink); font-weight:700; text-decoration:underline;
  text-decoration-thickness:2px; text-underline-offset:3px; text-decoration-color:var(--p-peach); }
.aside{ position:sticky; top:120px; }
.box{ background:var(--card); border:2px solid var(--ink); border-radius:14px;
  box-shadow:4px 4px 0 var(--ink); padding:20px; margin-bottom:20px; }
.box h4{ font:700 10px var(--mono); letter-spacing:.18em; text-transform:uppercase;
  color:var(--dim); margin-bottom:12px; }
.box .kv{ display:flex; justify-content:space-between; gap:12px; font-size:12px; padding:7px 0;
  border-bottom:1px solid var(--line); }
.box .kv:last-child{ border-bottom:0; }
.box .kv b{ font-weight:700; }
.related{ display:flex; flex-direction:column; gap:10px; }
.related a{ display:flex; align-items:center; gap:11px; text-decoration:none; padding:8px;
  border-radius:9px; }
.related a:hover{ background:var(--paper); }
.related .logo{ width:38px; height:38px; border-radius:10px; }
.related .logo img{ width:24px; height:24px; }
.related .logo svg{ width:20px; height:20px; }
.related b{ font:700 12px var(--mono); }
.related small{ display:block; font:400 10px var(--mono); color:var(--dim); }
.foot{ border-top:2px solid var(--ink); padding:40px 28px; text-align:center;
  font:500 11px var(--mono); letter-spacing:.04em; color:var(--dim); }
.foot a{ color:var(--ink); text-decoration:underline; text-underline-offset:3px;
  text-decoration-color:var(--p-blue); text-decoration-thickness:2px; }
@media (max-width:760px){
  .hero h1{ font-size:clamp(42px,12vw,68px); }
  .cols{ grid-template-columns:1fr; }
  .aside{ position:static; }
  .controls{ position:static; }
  .search{ flex:1 1 100%; order:3; }
  .count{ order:1; } .catsel{ order:2; }
}
"""


def logo_tile(item, cls=""):
    """Tasteful logo tile: real brand logo as <img>, else an inline library icon.

    Tile is pastel-tinted per toolkit; ink-colored icon. No monograms.
    """
    slug = item["slug"]
    tint = item.get("tint") or pastel_for(slug)
    style = f'style="background:{tint}"'
    if item.get("real_logo"):
        return (f'<span class="logo brand {cls}" {style}>'
                f'<img src="{item["logo"]}" alt="{html.escape(slug)} logo"></span>')
    # custom brand glyph only when the toolkit IS that noun; else a standard Lucide icon by category
    if slug in NOUN_GLYPH:
        return f'<span class="logo icon {cls}" {style}>{ICON_LIB[NOUN_GLYPH[slug]]}</span>'
    return f'<span class="logo icon {cls}" {style}>{lucide_for(item.get("category"))}</span>'


# ── index.html ──────────────────────────────────────────────────────────────

def render_index(items):
    cats = sorted({i["category"] for i in items})
    all_caps = sorted({c for i in items for c in i["caps"]})
    integrations = sorted({i["integration"] for i in items if i["integration"]})

    cards = []
    for i in items:
        chips = "".join(f'<span class="cc">{html.escape(c)}</span>' for c in i["caps"][:3])
        m_label, m_cls = maturity(i["status"])
        searchblob = " ".join([
            i["slug"], i["title"], i["tagline"], i["category"],
            i["integration"] or "", " ".join(i["caps"]),
        ]).lower()
        cards.append(f"""
    <a class="card" href="/toolkits/{i['slug']}.html"
       data-blob="{html.escape(searchblob)}"
       data-cat="{html.escape(i['category'])}">
      <div class="top">
        {logo_tile(i)}
        <div class="hd">
          <h3>{html.escape(i['title'])}</h3>
          <div class="ver">v{html.escape(i['version'])}</div>
        </div>
        <span class="badge-m m-{m_cls}">{m_label}</span>
      </div>
      <div class="tag">{html.escape(i['tagline'] or i['description'])}</div>
      <div class="meta"><span class="cc cat">{html.escape(i['category'])}</span>{chips}</div>
    </a>""")

    cat_opts = "".join(f'<option value="{html.escape(c)}">{html.escape(c)}</option>' for c in cats)

    extra = '<script type="application/ld+json">' + json.dumps({
        "@context": "https://schema.org", "@type": "CollectionPage",
        "name": "Toolkit Marketplace — Workbooks",
        "description": "The marketplace of capabilities and integrations any Workbooks workbook or agent can install.",
        "url": "https://workbooks.sh/toolkits/",
    }) + "</script>"

    body = f"""<body>
{NAV}
<section class="hero">
  <div class="kick">The Workbooks Marketplace</div>
  <h1>The powers <em>your workbook</em> can <span class="rot" id="rot">install</span></h1>
  <p>Toolkits are the capabilities a workbook — or its agent — reaches for: sandboxed-WASM
  powers and live service integrations alike. Add one with <code>wbx toolkit add</code>
  and it's wired straight into the workbook's Dock. Search the catalog, open any one for
  the full write-up.</p>
  <div class="stat">
    <span class="badge"><b>{len(items)}</b><span>toolkits</span></span>
    <span class="badge"><b>{len(all_caps)}</b><span>capabilities</span></span>
    <span class="badge"><b>{len(integrations)}</b><span>integrations</span></span>
  </div>
</section>

<div class="controls">
  <div class="wrap">
    <div class="count" id="count"></div>
    <select class="catsel" id="cat" aria-label="Filter by category">
      <option value="">All categories</option>
      {cat_opts}
    </select>
    <label class="search">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><circle cx="10.5" cy="10.5" r="7"/><path d="M21 21l-5.2-5.2"/></svg>
      <input id="q" type="search" placeholder="Search toolkits, capabilities…" autocomplete="off">
    </label>
  </div>
</div>

<div class="wrap">
  <div class="grid" id="grid">{''.join(cards)}</div>
  <div class="empty" id="empty" style="display:none">No toolkits match — try another search.</div>
</div>

<div class="foot">
  Open source · forever — <a href="https://github.com/workbooks-sh/toolkits">github.com/workbooks-sh/toolkits</a>
  · <a href="https://docs.workbooks.sh/">read the docs</a>
</div>

<script>
(function(){{
  var el=document.getElementById('rot'); if(!el) return;
  var words=["install","use","build","integrate","extend"];
  var cols=["#d9c5f0","#aee5c2","#a8d4f0","#f3c5a3","#b8e0e8"];
  if(window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches){{
    el.textContent=words[0]; el.style.setProperty('--rotc',cols[0]); el.classList.add('norot'); return;
  }}
  var wi=0, ci=0, dir=1;
  function tick(){{
    var w=words[wi];
    el.style.setProperty('--rotc',cols[wi]);
    el.textContent=w.slice(0,ci);
    if(dir>0){{ ci++; if(ci>w.length){{ dir=-1; ci=w.length; setTimeout(tick,1500); return; }} }}
    else{{ ci--; if(ci<0){{ dir=1; ci=0; wi=(wi+1)%words.length; setTimeout(tick,240); return; }} }}
    setTimeout(tick, dir>0?95:48);
  }}
  tick();
}})();
(function(){{
  var q=document.getElementById('q'), cat=document.getElementById('cat');
  var grid=document.getElementById('grid');
  var cards=[].slice.call(grid.querySelectorAll('.card'));
  var count=document.getElementById('count'), empty=document.getElementById('empty');

  function apply(){{
    var term=(q.value||'').trim().toLowerCase();
    var terms=term?term.split(/\\s+/):[];
    var c2=cat.value;
    var shown=0;
    cards.forEach(function(c){{
      var blob=c.dataset.blob;
      var okTerm=terms.every(function(t){{return blob.indexOf(t)>=0;}});
      var okCat=!c2 || c.dataset.cat===c2;
      var ok=okTerm && okCat;
      c.style.display=ok?'':'none';
      if(ok) shown++;
    }});
    count.textContent=shown+' of '+cards.length+' toolkits';
    empty.style.display=shown?'none':'block';
  }}
  q.addEventListener('input', apply);
  cat.addEventListener('change', apply);
  var p=new URLSearchParams(location.search);
  if(p.get('cat')){{ cat.value=p.get('cat'); }}
  if(p.get('q')){{ q.value=p.get('q'); }}
  apply();
}})();
</script>
</body>
</html>"""
    return head(
        "Toolkit Marketplace — Workbooks",
        "The marketplace of capabilities and integrations any Workbooks workbook or agent can install — search and filter by capability, category, and integration.",
        "https://workbooks.sh/toolkits/", extra) + "\n" + body


# ── detail pages ────────────────────────────────────────────────────────────

def render_detail(item, all_items):
    i = item
    m_label, m_cls = maturity(i["status"])
    # related: same category (excluding self), up to 4
    related = [x for x in all_items if x["category"] == i["category"] and x["slug"] != i["slug"]][:4]
    if len(related) < 3:
        for x in all_items:
            if x["slug"] != i["slug"] and x not in related:
                related.append(x)
            if len(related) >= 4:
                break

    caps_html = "".join(f'<span class="cc">{html.escape(c)}</span>' for c in i["caps"]) or \
        '<span class="dim">general capability</span>'

    add_cmd = f"wbx toolkit add {i['slug']}"

    # integration write-up
    if i["integration"]:
        integ = (f"<p><b>{html.escape(i['integration'])}.</b> This toolkit connects a workbook to "
                 f"{html.escape(i['integration'])}. ")
        if i["env_keys"]:
            integ += (f"It reads its credential from the environment "
                      f"(<code>{html.escape(', '.join(i['env_keys']))}</code>) — toolkits never store keys; "
                      f"the host injects them at run time, scoped to the workbook's trust context. ")
        if i["env_note"]:
            integ += html.escape(i["env_note"])
        integ += "</p>"
    else:
        integ = ("<p>This is a <b>self-contained capability</b> — no external account or key required. "
                 "It runs inside the workbook's sandbox and is reachable through the Dock the moment it's added.</p>")
        if i["requires"]:
            integ += f"<p class=\"dim\">Requires: <code>{html.escape(i['requires'])}</code></p>"

    flow_html = ""
    if i["flow"]:
        flow_html = f"""
    <div class="sec">
      <h2>The flow</h2>
      <p class="dim">{html.escape(i['flow'])}</p>
    </div>"""

    related_html = "".join(f"""
      <a href="/toolkits/{r['slug']}.html">
        {logo_tile(r)}
        <span><b>{html.escape(r['title'])}</b><small>{html.escape(r['category'])} · v{html.escape(r['version'])}</small></span>
      </a>""" for r in related)

    kv = [("Version", "v" + i["version"]), ("Kind", i["kind"]), ("Category", i["category"]),
          ("Maturity", m_label)]
    if i["cli_bin"]:
        kv.append(("CLI", i["cli_bin"]))
    if i["integration"]:
        kv.append(("Integration", i["integration"]))
    if i["updated"]:
        kv.append(("Updated", i["updated"]))
    kv_html = "".join(f'<div class="kv"><span class="dim">{html.escape(k)}</span><b>{html.escape(str(v))}</b></div>'
                      for k, v in kv)

    extra = '<script type="application/ld+json">' + json.dumps({
        "@context": "https://schema.org", "@type": "SoftwareApplication",
        "name": i["title"] + " — Workbooks toolkit",
        "applicationCategory": "DeveloperApplication",
        "softwareVersion": i["version"],
        "description": i["tagline"] or i["description"],
        "url": f"https://workbooks.sh/toolkits/{i['slug']}.html",
        "isPartOf": {"@type": "WebSite", "name": "Workbooks", "url": "https://workbooks.sh/"},
    }) + "</script>"

    body = f"""<body>
{NAV}
<main class="detail">
  <div class="crumb"><a href="/toolkits/">Marketplace</a> / {html.escape(i['title'])}</div>

  <div class="dhead">
    {logo_tile(i)}
    <div>
      <h1>{html.escape(i['title'])}</h1>
      <div class="meta">
        <span class="badge-m m-{m_cls}">{m_label}</span>
        <span class="cc cat">{html.escape(i['category'])}</span>
        <span class="cc">v{html.escape(i['version'])}</span>
      </div>
      <p class="lede">{html.escape(i['tagline'] or i['description'])}</p>
    </div>
  </div>

  <div class="cols">
    <div>
      <div class="sec">
        <h2>What it does</h2>
        <p>{html.escape(i['description'] or i['tagline'])}</p>
      </div>

      <div class="sec">
        <h2>Capabilities it grants</h2>
        <div class="caplist">{caps_html}</div>
      </div>

      <div class="sec">
        <h2>Add it to a workbook</h2>
        <div class="install">
          <span>$ <code>{html.escape(add_cmd)}</code></span>
          <button data-copy="{html.escape(add_cmd)}">Copy</button>
        </div>
        <p class="dim" style="margin-top:14px">Once added, the toolkit is wired into the workbook's Dock —
        the agent reaches its verbs by name, the host brokers any capability it needs.
        <a class="docs" href="https://docs.workbooks.sh/toolkits/{html.escape(i['slug'])}">Read the docs →</a></p>
      </div>

      <div class="sec">
        <h2>Integration</h2>
        {integ}
      </div>
      {flow_html}
    </div>

    <aside class="aside">
      <div class="box">
        <h4>At a glance</h4>
        {kv_html}
      </div>
      <div class="box">
        <h4>Related toolkits</h4>
        <div class="related">{related_html}</div>
      </div>
    </aside>
  </div>
</main>

<div class="foot">
  Open source · forever — <a href="https://github.com/workbooks-sh/toolkits">github.com/workbooks-sh/toolkits</a>
  · <a href="/toolkits/">back to the marketplace</a>
</div>

<script>
document.querySelectorAll('button[data-copy]').forEach(function(b){{
  b.addEventListener('click', async function(){{
    try{{ await navigator.clipboard.writeText(b.dataset.copy); }}catch(e){{}}
    var t=b.textContent; b.textContent='Copied ✓';
    setTimeout(function(){{ b.textContent=t; }}, 1400);
  }});
}});
</script>
</body>
</html>"""
    return head(
        f"{i['title']} — Workbooks toolkit",
        (i["tagline"] or i["description"])[:300],
        f"https://workbooks.sh/toolkits/{i['slug']}.html", extra) + "\n" + body


# ── main ────────────────────────────────────────────────────────────────────

def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    items = build_catalog()

    # 1. catalog.json (public shape — drop internal-only fields)
    _drop = {"real_logo"}
    public = [{k: v for k, v in i.items() if k not in _drop} for i in items]
    with open(os.path.join(OUT_DIR, "catalog.json"), "w", encoding="utf-8") as f:
        json.dump(public, f, indent=2)

    # 2. index.html
    with open(os.path.join(OUT_DIR, "index.html"), "w", encoding="utf-8") as f:
        f.write(render_index(items))

    # 3. <slug>.html
    for i in items:
        with open(os.path.join(OUT_DIR, f"{i['slug']}.html"), "w", encoding="utf-8") as f:
            f.write(render_detail(i, items))

    print(f"catalog.json: {len(items)} toolkits")
    print(f"index.html: 1")
    print(f"detail pages: {len(items)}")
    print("generated:", datetime.now(timezone.utc).isoformat())


if __name__ == "__main__":
    main()

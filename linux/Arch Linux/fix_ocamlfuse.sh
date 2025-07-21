#!/bin/bash

# Copyright (c) 2025 Rámon van Raaij

# License: MIT

# Author: Rámon van Raaij | X: @ramonvanraaij | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu

# fix_ocamlfuse.sh - Resolves common issues encountered when updating the AUR ocamlfuse package.

# Prerequisite packages: ocaml-seq, opam, camlidl

# Ensure opam is initialized with default settings (option 5)
echo "Initializing opam without user interaction..."
yes 5 | opam init --disable-sandboxing

# Check if opam init was successful
if [ $? -eq 0 ]; then
    echo "opam init completed successfully."
    # Install ocamlfuse using yay
    echo "Installing ocamlfuse using yay..."
    yay -Syuq --aur --needed --noconfirm --norebuild --noredownload

    if [ $? -eq 0 ]; then
        echo "ocamlfuse installed successfully."
    else
        echo "Error: ocamlfuse installation failed."
        echo "Please check your yay configuration and try running 'yay -S ocamlfuse' manually."
    fi
else
    echo "Error: opam init failed."
    echo "Please check the opam output above for details."
fi

echo "Script finished."

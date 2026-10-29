// common/ca_bundle.h — materialize the CA bundle that is compiled into IEC.
//
// The device has no trust store at the path libcurl would look at, and libcurl
// here is built without a default CA path. Instead of shipping a second copy as
// a raw resource (which the app would have to extract), the bundle is embedded
// into the library by tools/embed_file.py and written out on demand.
#pragma once

// Writes the embedded bundle to <dir>/cacert.pem, creating <dir> and its
// parents. Existing files are replaced. Returns true when the file is complete.
bool IecInstallCaBundle(const char* dir);

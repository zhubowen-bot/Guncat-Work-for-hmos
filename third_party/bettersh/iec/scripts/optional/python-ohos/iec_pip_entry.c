/* iec_pip_entry.c — `pip` command entry: turn it into `python -m pip ...`.
 *
 * Why this layer exists: an IEC launcher names one object, one entry symbol and
 * an arity; it cannot express fixed leading arguments. pip is not a standalone
 * program, it is a Python module, and the standard invocation is
 * `python -m pip`. This entry builds that argument vector and calls
 * Py_BytesMain, the same symbol the python/python3 launchers use.
 *
 * The object is linked into libpython.so, so Py_BytesMain is a direct reference
 * within the same shared object.
 *
 * It deliberately does not set PIP_* variables; configuration belongs to the
 * application's rc file.
 */
#include <stdlib.h>

extern int Py_BytesMain(int argc, char **argv);

int iec_pip_main(int argc, char **argv)
{
    const int n = argc + 3;
    char **nv = (char **)calloc((size_t)n + 1, sizeof(char *));
    int k = 0;

    if (!nv) return 1;
    nv[k++] = (char *)"python";
    nv[k++] = (char *)"-m";
    nv[k++] = (char *)"pip";
    for (int i = 1; i < argc; i++) nv[k++] = argv[i];
    nv[k] = NULL;

    {
        int rc = Py_BytesMain(k, nv);
        free(nv);
        return rc;
    }
}

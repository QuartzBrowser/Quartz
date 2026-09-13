#include <errno.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

extern char **environ;

static void fail(const char *message)
{
    fprintf(stderr, "Quartz: %s\n", message);
    exit(EXIT_FAILURE);
}

static char *append_path(const char *directory, const char *name)
{
    char *result = NULL;
    if (asprintf(&result, "%s/%s", directory, name) < 0)
        fail("Could not allocate the application paths.");
    return result;
}

static int is_loader_variable(const char *entry)
{
    return strncmp(entry, "DYLD_", 5) == 0 || strncmp(entry, "__XPC_DYLD_", 11) == 0;
}

static void clear_loader_environment(void)
{
    for (size_t index = 0; environ[index] != NULL;) {
        const char *entry = environ[index];
        if (!is_loader_variable(entry)) {
            ++index;
            continue;
        }
        size_t length = strcspn(entry, "=");
        char *name = strndup(entry, length);
        if (name == NULL)
            fail("Could not clear inherited loader settings.");
        int result = unsetenv(name);
        free(name);
        if (result != 0)
            fail("Could not clear inherited loader settings.");
        // unsetenv shifts the remaining entries; inspect this index again.
    }
}

int main(int argc, char *argv[])
{
    if (argc < 1 || argv == NULL || argv[0] == NULL)
        fail("Could not read the application launch arguments.");
    uint32_t size = 0;
    (void)_NSGetExecutablePath(NULL, &size);
    char *unresolved = malloc(size);
    if (unresolved == NULL || _NSGetExecutablePath(unresolved, &size) != 0)
        fail("Could not locate the application launcher.");
    char *executable = realpath(unresolved, NULL);
    free(unresolved);
    if (executable == NULL)
        fail("Could not resolve the application launcher path.");

    char *separator = strrchr(executable, '/');
    if (separator == NULL)
        fail("The launcher must be inside the Quartz application bundle.");
    *separator = '\0';
    char *macos = executable;
    separator = strrchr(macos, '/');
    if (separator == NULL || strcmp(separator + 1, "MacOS") != 0)
        fail("The launcher must be inside Contents/MacOS.");
    char *contents = strndup(macos, (size_t)(separator - macos));
    if (contents == NULL)
        fail("Could not allocate the application paths.");
    separator = strrchr(contents, '/');
    if (separator == NULL || strcmp(separator + 1, "Contents") != 0)
        fail("The launcher must be inside Contents/MacOS.");

    char *runtime = append_path(macos, "QuartzRuntime");
    char *frameworks = append_path(contents, "Frameworks");
    if (strchr(frameworks, ':') != NULL)
        fail("Move Quartz to a location without a colon in its path.");
    struct stat status;
    if (lstat(runtime, &status) != 0 || !S_ISREG(status.st_mode) || access(runtime, X_OK) != 0)
        fail("Missing executable Contents/MacOS/QuartzRuntime. Reinstall Quartz.");
    if (lstat(frameworks, &status) != 0 || !S_ISDIR(status.st_mode))
        fail("Missing Contents/Frameworks directory. Reinstall Quartz.");

    clear_loader_environment();
    if (setenv("DYLD_FRAMEWORK_PATH", frameworks, 1) != 0
        || setenv("__XPC_DYLD_FRAMEWORK_PATH", frameworks, 1) != 0)
        fail("Could not configure the bundled WebKit engine.");

    argv[0] = runtime;
    execv(runtime, argv);
    fprintf(stderr, "Quartz: Could not start QuartzRuntime: %s\n", strerror(errno));
    return EXIT_FAILURE;
}

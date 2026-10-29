/* Data symbols required by GNU <error.h> contract. */
#include <stddef.h>
unsigned int error_message_count = 0;
int          error_one_per_line  = 0;
void       (*error_print_progname)(void) = NULL;

/* notmuch - Not much of an email program, (just index and search)
 *
 * Copyright © 2009 Carl Worth
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see http://www.gnu.org/licenses/ .
 *
 * Author: Carl Worth <cworth@cworth.org>
 */

#include "notmuch-client.h"

static const char *
make_path_absolute (void *ctx, const char *path)
{
    char *cwd;

    if (*path == '/')
	return path;

    cwd = getcwd (NULL, 0);
    if (cwd == NULL) {
	fprintf (stderr, "Out of memory.\n");
	return NULL;
    }

    path = talloc_asprintf (ctx, "%s/%s", cwd, path);
    if (path == NULL)
	fprintf (stderr, "Out of memory.\n");

    free (cwd);

    return path;
}

static void
welcome_message_pre_setup (void)
{
    printf (
"Welcome to notmuch!\n\n"

"The goal of notmuch is to help you manage and search your collection of\n"
"email, and to efficiently keep up with the flow of email as it comes in.\n\n"

"Notmuch needs to know a few things about you such as your name and email\n"
"address, as well as the directory that contains your email. This is where\n"
"you already have mail stored and where messages will be delivered in the\n"
"future. This directory can contain any number of sub-directories. Regular\n"
"files in these directories should be individual email messages. If there\n"
"are other, non-email files (such as indexes maintained by other email\n"
"programs) then notmuch will do its best to detect those and ignore them.\n\n"

"If you already have your email being delivered to directories in either\n"
"maildir or mh format, then that's perfect. Mail storage that uses mbox\n"
"format, (where one mbox file contains many messages), will not work with\n"
"notmuch. If that's how your mail is currently stored, we recommend you\n"
"first convert it to maildir format with a utility such as mb2md. You can\n"
"continue configuring notmuch now, but be sure to complete the conversion\n"
"before you run \"notmuch new\" for the first time.\n\n");
}

static void
welcome_message_post_setup (void)
{
    printf ("\n"
"Notmuch is now configured, and the configuration settings are saved in\n"
"a file in your home directory named .notmuch-config . If you'd like to\n"
"change the configuration in the future, you can either edit that file\n"
"directly or run \"notmuch setup\".  To choose an alternate configuration\n"
"location, set ${NOTMUCH_CONFIG}.\n\n"

"The next step is to run \"notmuch new\" which will create a database\n"
"that indexes all of your mail. Depending on the amount of mail you have\n"
"the initial indexing process can take a long time, so expect that.\n"
"Also, the resulting database will require roughly the same amount of\n"
"storage space as your current collection of email. So please ensure you\n"
"have sufficient storage space available now.\n\n");
}

int
notmuch_setup_command (unused (void *ctx),
		       unused (int argc), unused (char *argv[]))
{
    char *response = NULL;
    size_t response_size;
    notmuch_config_t *config;
    char **old_other_emails;
    size_t old_other_emails_len;
    GPtrArray *other_emails;
    unsigned int i;
    int is_new;
    const char **new_tags;
    size_t new_tags_len;

#define prompt(format, ...)					\
    do {							\
	printf (format, ##__VA_ARGS__);				\
	fflush (stdout);					\
	if (getline (&response, &response_size, stdin) < 0) {	\
	    printf ("Exiting.\n");				\
	    exit (1);						\
	}							\
	chomp_newline (response);				\
    } while (0)

    config = notmuch_config_open (ctx, NULL, &is_new);

    if (is_new)
	welcome_message_pre_setup ();

    prompt ("Your full name [%s]: ", notmuch_config_get_user_name (config));
    if (strlen (response))
	notmuch_config_set_user_name (config, response);

    prompt ("Your primary email address [%s]: ",
	    notmuch_config_get_user_primary_email (config));
    if (strlen (response))
	notmuch_config_set_user_primary_email (config, response);

    other_emails = g_ptr_array_new ();

    old_other_emails = notmuch_config_get_user_other_email (config,
					     &old_other_emails_len);
    for (i = 0; i < old_other_emails_len; i++) {
	prompt ("Additional email address [%s]: ", old_other_emails[i]);
	if (strlen (response))
	    g_ptr_array_add (other_emails, talloc_strdup (ctx, response));
	else
	    g_ptr_array_add (other_emails, talloc_strdup (ctx,
							 old_other_emails[i]));
    }

    do {
	prompt ("Additional email address [Press 'Enter' if none]: ");
	if (strlen (response))
	    g_ptr_array_add (other_emails, talloc_strdup (ctx, response));
    } while (strlen (response));
    if (other_emails->len)
	notmuch_config_set_user_other_email (config,
					     (const char **)
					     other_emails->pdata,
					     other_emails->len);
    g_ptr_array_free (other_emails, TRUE);

    prompt ("Top-level directory of your email archive [%s]: ",
	    notmuch_config_get_database_path (config));
    if (strlen (response)) {
	const char *absolute_path;

	absolute_path = make_path_absolute (ctx, response);
	notmuch_config_set_database_path (config, absolute_path);
    }

    new_tags = notmuch_config_get_new_tags (config, &new_tags_len);

    printf ("Tags to apply to all new messages (separated by spaces) [");

    for (i = 0; i < new_tags_len; i++) {
	if (i != 0)
	    printf (" ");
	printf ("%s", new_tags[i]);
    }

    prompt ("]: ");

    if (strlen (response)) {
	GPtrArray *tags = g_ptr_array_new ();
	char *tag = response;
	char *space;

	while (tag && *tag) {
	    space = strchr (tag, ' ');
	    if (space)
		g_ptr_array_add (tags, talloc_strndup (ctx, tag, space - tag));
	    else
		g_ptr_array_add (tags, talloc_strdup (ctx, tag));
	    tag = space;
	    while (tag && *tag == ' ')
		tag++;
	}

	notmuch_config_set_new_tags (config, (const char **) tags->pdata,
				     tags->len);

	g_ptr_array_free (tags, TRUE);
    }

    printf ("\n"
	    "Notmuch can synchronize certain tags with maildir flags. You can\n"
	    "select between several levels of synchronization:\n"
	    "1 - No synchronization at all.\n"
	    "2 - 'notmuch new' tags the messages based on their maildir flags\n"
	    "    only when it sees them for the first time.\n"
	    "3 - Same as 2 plus 'notmuch new' updates tags when it detects the\n"
	    "    message was renamed.\n"
	    "4 - Same as 3 plus whenever message tags are changed, maildir\n"
	    "    flags are updated accordingly.\n");

    prompt ("Maildir synchronization level [%d]: ", notmuch_config_get_maildir_sync (config));
    if (strlen (response) == 1 &&
	response[0] >= '1' &&
	response[0] <= '4')
	notmuch_config_set_maildir_sync (config, atoi (response));

    if (! notmuch_config_save (config)) {
	if (is_new)
	  welcome_message_post_setup ();
	return 0;
    } else {
	return 1;
    }
}

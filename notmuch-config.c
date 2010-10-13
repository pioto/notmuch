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

#include <pwd.h>
#include <netdb.h>

static const char toplevel_config_comment[] =
    " .notmuch-config - Configuration file for the notmuch mail system\n"
    "\n"
    " For more information about notmuch, see http://notmuchmail.org";

static const char database_config_comment[] =
    " Database configuration\n"
    "\n"
    " The only value supported here is 'path' which should be the top-level\n"
    " directory where your mail currently exists and to where mail will be\n"
    " delivered in the future. Files should be individual email messages.\n"
    " Notmuch will store its database within a sub-directory of the path\n"
    " configured here named \".notmuch\".\n";

static const char new_config_comment[] =
    " Configuration for \"notmuch new\"\n"
    "\n"
    " The following options are supported here:\n"
    "\n"
    "\ttags	A list (separated by ';') of the tags that will be\n"
    "\t	added to all messages incorporated by \"notmuch new\".\n";

static const char user_config_comment[] =
    " User configuration\n"
    "\n"
    " Here is where you can let notmuch know how you would like to be\n"
    " addressed. Valid settings are\n"
    "\n"
    "\tname		Your full name.\n"
    "\tprimary_email	Your primary email address.\n"
    "\tother_email	A list (separated by ';') of other email addresses\n"
    "\t		at which you receive email.\n"
    "\n"
    " Notmuch will use the various email addresses configured here when\n"
    " formatting replies. It will avoid including your own addresses in the\n"
    " recipient list of replies, and will set the From address based on the\n"
    " address to which the original email was addressed.\n";

static const char maildir_config_comment[] =
    " Maildir compatibility configuration\n"
    "\n"
    " Here you can configure whether and how will notmuch synchronize its\n"
    " tags with maildir flags."
    "\n"
    "\tsync_level      Integer in the range 1 - 4 with the following meaning:\n"
    "\t\t1 - No synchronization at all.\n"
    "\t\t2 - 'notmuch new' tags the messages based on their maildir flags\n"
    "\t\t    only when it sees them for the first time.\n"
    "\t\t3 - Same as 2 plus 'notmuch new' updates tags when it detects the\n"
    "\t\t    message was renamed.\n"
    "\t\t4 - Same as 3 plus whenever message tags are changed, maildir\n"
    "\t\t    flags are updated accordingly.\n";

struct _notmuch_config {
    char *filename;
    GKeyFile *key_file;

    char *database_path;
    char *user_name;
    char *user_primary_email;
    char **user_other_email;
    size_t user_other_email_length;
    const char **new_tags;
    size_t new_tags_length;
    enum notmuch_maildir_sync maildir_sync;
};

static int
notmuch_config_destructor (notmuch_config_t *config)
{
    if (config->key_file)
	g_key_file_free (config->key_file);

    return 0;
}

static char *
get_name_from_passwd_file (void *ctx)
{
    long pw_buf_size = sysconf(_SC_GETPW_R_SIZE_MAX);
    char *pw_buf = talloc_zero_size (ctx, pw_buf_size);
    struct passwd passwd, *ignored;
    char *name;
    int e;

    if (pw_buf_size == -1) pw_buf_size = 64;

    while ((e = getpwuid_r (getuid (), &passwd, pw_buf,
                            pw_buf_size, &ignored)) == ERANGE) {
        pw_buf_size = pw_buf_size * 2;
        pw_buf = talloc_zero_size(ctx, pw_buf_size);
    }

    if (e == 0) {
	char *comma = strchr (passwd.pw_gecos, ',');
	if (comma)
	    name = talloc_strndup (ctx, passwd.pw_gecos,
				   comma - passwd.pw_gecos);
	else
	    name = talloc_strdup (ctx, passwd.pw_gecos);
    } else {
	name = talloc_strdup (ctx, "");
    }

    talloc_free (pw_buf);

    return name;
}

static char *
get_username_from_passwd_file (void *ctx)
{
    long pw_buf_size = sysconf(_SC_GETPW_R_SIZE_MAX);
    char *pw_buf = talloc_zero_size (ctx, pw_buf_size);
    struct passwd passwd, *ignored;
    char *name;
    int e;

    if (pw_buf_size == -1) pw_buf_size = 64;
    while ((e = getpwuid_r (getuid (), &passwd, pw_buf,
                            pw_buf_size, &ignored)) == ERANGE) {
        pw_buf_size = pw_buf_size * 2;
        pw_buf = talloc_zero_size(ctx, pw_buf_size);
    }

    if (e == 0)
	name = talloc_strdup (ctx, passwd.pw_name);
    else
	name = talloc_strdup (ctx, "");

    talloc_free (pw_buf);

    return name;
}

/* Open the named notmuch configuration file. If the filename is NULL,
 * the value of the environment variable $NOTMUCH_CONFIG will be used.
 * If $NOTMUCH_CONFIG is unset, the default configuration file
 * ($HOME/.notmuch-config) will be used.
 *
 * If any error occurs, (out of memory, or a permission-denied error,
 * etc.), this function will print a message to stderr and return
 * NULL.
 *
 * FILE NOT FOUND: When the specified configuration file (whether from
 * 'filename' or the $NOTMUCH_CONFIG environment variable) does not
 * exist, the behavior of this function depends on the 'is_new_ret'
 * variable.
 *
 *	If is_new_ret is NULL, then a "file not found" message will be
 *	printed to stderr and NULL will be returned.

 *	If is_new_ret is non-NULL then a default configuration will be
 *	returned and *is_new_ret will be set to 1 on return so that
 *	the caller can recognize this case.
 *
 * 	These default configuration settings are determined as
 * 	follows:
 *
 *		database_path:		$HOME/mail
 *
 *		user_name:		From /etc/passwd
 *
 *		user_primary_mail: 	$EMAIL variable if set, otherwise
 *					constructed from the username and
 *					hostname of the current machine.
 *
 *		user_other_email:	Not set.
 *
 *	The default configuration also contains comments to guide the
 *	user in editing the file directly.
 */
notmuch_config_t *
notmuch_config_open (void *ctx,
		     const char *filename,
		     notmuch_bool_t *is_new_ret)
{
    GError *error = NULL;
    int is_new = 0;
    size_t tmp;
    char *notmuch_config_env = NULL;
    int file_had_database_group;
    int file_had_new_group;
    int file_had_user_group;
    int file_had_maildir_group;

    if (is_new_ret)
	*is_new_ret = 0;

    notmuch_config_t *config = talloc (ctx, notmuch_config_t);
    if (config == NULL) {
	fprintf (stderr, "Out of memory.\n");
	return NULL;
    }
    
    talloc_set_destructor (config, notmuch_config_destructor);

    if (filename) {
	config->filename = talloc_strdup (config, filename);
    } else if ((notmuch_config_env = getenv ("NOTMUCH_CONFIG"))) {
	config->filename = talloc_strdup (config, notmuch_config_env);
    } else {
	config->filename = talloc_asprintf (config, "%s/.notmuch-config",
					    getenv ("HOME"));
    }

    config->key_file = g_key_file_new ();

    config->database_path = NULL;
    config->user_name = NULL;
    config->user_primary_email = NULL;
    config->user_other_email = NULL;
    config->user_other_email_length = 0;
    config->new_tags = NULL;
    config->new_tags_length = 0;
    config->maildir_sync = NOTMUCH_MAILDIR_SYNC_INVALID;

    if (! g_key_file_load_from_file (config->key_file,
				     config->filename,
				     G_KEY_FILE_KEEP_COMMENTS,
				     &error))
    {
	/* If the caller passed a non-NULL value for is_new_ret, then
	 * the caller is prepared for a default configuration file in
	 * the case of FILE NOT FOUND. Otherwise, any read failure is
	 * an error.
	 */
	if (is_new_ret &&
	    error->domain == G_FILE_ERROR &&
	    error->code == G_FILE_ERROR_NOENT)
	{
	    g_error_free (error);
	    is_new = 1;
	}
	else
	{
	    fprintf (stderr, "Error reading configuration file %s: %s\n",
		     config->filename, error->message);
	    talloc_free (config);
	    g_error_free (error);
	    return NULL;
	}
    }

    /* Whenever we know of configuration sections that don't appear in
     * the configuration file, we add some comments to help the user
     * understand what can be done.
     *
     * It would be convenient to just add those comments now, but
     * apparently g_key_file will clear any comments when keys are
     * added later that create the groups. So we have to check for the
     * groups now, but add the comments only after setting all of our
     * values.
     */
    file_had_database_group = g_key_file_has_group (config->key_file,
						    "database");
    file_had_new_group = g_key_file_has_group (config->key_file, "new");
    file_had_user_group = g_key_file_has_group (config->key_file, "user");
    file_had_maildir_group = g_key_file_has_group (config->key_file, "maildir");


    if (notmuch_config_get_database_path (config) == NULL) {
	char *path = talloc_asprintf (config, "%s/mail",
				      getenv ("HOME"));
	notmuch_config_set_database_path (config, path);
	talloc_free (path);
    }

    if (notmuch_config_get_user_name (config) == NULL) {
	char *name = get_name_from_passwd_file (config);
	notmuch_config_set_user_name (config, name);
	talloc_free (name);
    }

    if (notmuch_config_get_user_primary_email (config) == NULL) {
	char *email = getenv ("EMAIL");
	if (email) {
	    notmuch_config_set_user_primary_email (config, email);
	} else {
	    char hostname[256];
	    struct hostent *hostent;
	    const char *domainname;

	    char *username = get_username_from_passwd_file (config);

	    gethostname (hostname, 256);
	    hostname[255] = '\0';

	    hostent = gethostbyname (hostname);
	    if (hostent && (domainname = strchr (hostent->h_name, '.')))
		domainname += 1;
	    else
		domainname = "(none)";

	    email = talloc_asprintf (config, "%s@%s.%s",
				     username, hostname, domainname);

	    notmuch_config_set_user_primary_email (config, email);

	    talloc_free (username);
	    talloc_free (email);
	}
    }

    if (notmuch_config_get_new_tags (config, &tmp) == NULL) {
        const char *tags[] = { "unread", "inbox" };
	notmuch_config_set_new_tags (config, tags, 2);
    }

    if (notmuch_config_get_maildir_sync (config) == NOTMUCH_MAILDIR_SYNC_INVALID) {
	notmuch_config_set_maildir_sync (config, NOTMUCH_MAILDIR_SYNC_NONE);
    }

    /* Whenever we know of configuration sections that don't appear in
     * the configuration file, we add some comments to help the user
     * understand what can be done. */
    if (is_new)
    {
	g_key_file_set_comment (config->key_file, NULL, NULL,
				toplevel_config_comment, NULL);
    }

    if (! file_had_database_group)
    {
	g_key_file_set_comment (config->key_file, "database", NULL,
				database_config_comment, NULL);
    }

    if (! file_had_new_group)
    {
	g_key_file_set_comment (config->key_file, "new", NULL,
				new_config_comment, NULL);
    }

    if (! file_had_user_group)
    {
	g_key_file_set_comment (config->key_file, "user", NULL,
				user_config_comment, NULL);
    }

    if (! file_had_maildir_group)
    {
	g_key_file_set_comment (config->key_file, "maildir", NULL,
				maildir_config_comment, NULL);
    }

    if (is_new_ret)
	*is_new_ret = is_new;

    return config;
}

/* Close the given notmuch_config_t object, freeing all resources.
 * 
 * Note: Any changes made to the configuration are *not* saved by this
 * function. To save changes, call notmuch_config_save before
 * notmuch_config_close.
*/
void
notmuch_config_close (notmuch_config_t *config)
{
    talloc_free (config);
}

/* Save any changes made to the notmuch configuration.
 *
 * Any comments originally in the file will be preserved.
 *
 * Returns 0 if successful, and 1 in case of any error, (after
 * printing a description of the error to stderr).
 */
int
notmuch_config_save (notmuch_config_t *config)
{
    size_t length;
    char *data;
    GError *error = NULL;

    data = g_key_file_to_data (config->key_file, &length, NULL);
    if (data == NULL) {
	fprintf (stderr, "Out of memory.\n");
	return 1;
    }

    if (! g_file_set_contents (config->filename, data, length, &error)) {
	fprintf (stderr, "Error saving configuration to %s: %s\n",
		 config->filename, error->message);
	g_error_free (error);
	g_free (data);
	return 1;
    }

    g_free (data);
    return 0;
}

const char *
notmuch_config_get_database_path (notmuch_config_t *config)
{
    char *path;

    if (config->database_path == NULL) {
	path = g_key_file_get_string (config->key_file,
				      "database", "path", NULL);
	if (path) {
	    config->database_path = talloc_strdup (config, path);
	    free (path);
	}
    }

    return config->database_path;
}

void
notmuch_config_set_database_path (notmuch_config_t *config,
				  const char *database_path)
{
    g_key_file_set_string (config->key_file,
			   "database", "path", database_path);

    talloc_free (config->database_path);
    config->database_path = NULL;
}

const char *
notmuch_config_get_user_name (notmuch_config_t *config)
{
    char *name;

    if (config->user_name == NULL) {
	name = g_key_file_get_string (config->key_file,
				      "user", "name", NULL);
	if (name) {
	    config->user_name = talloc_strdup (config, name);
	    free (name);
	}
    }

    return config->user_name;
}

void
notmuch_config_set_user_name (notmuch_config_t *config,
			      const char *user_name)
{
    g_key_file_set_string (config->key_file,
			   "user", "name", user_name);

    talloc_free (config->user_name);
    config->user_name = NULL;
}

const char *
notmuch_config_get_user_primary_email (notmuch_config_t *config)
{
    char *email;

    if (config->user_primary_email == NULL) {
	email = g_key_file_get_string (config->key_file,
				       "user", "primary_email", NULL);
	if (email) {
	    config->user_primary_email = talloc_strdup (config, email);
	    free (email);
	}
    }

    return config->user_primary_email;
}

void
notmuch_config_set_user_primary_email (notmuch_config_t *config,
				       const char *primary_email)
{
    g_key_file_set_string (config->key_file,
			   "user", "primary_email", primary_email);

    talloc_free (config->user_primary_email);
    config->user_primary_email = NULL;
}

char **
notmuch_config_get_user_other_email (notmuch_config_t *config,
				     size_t *length)
{
    char **emails;
    size_t emails_length;
    unsigned int i;

    if (config->user_other_email == NULL) {
	emails = g_key_file_get_string_list (config->key_file,
					     "user", "other_email",
					     &emails_length, NULL);
	if (emails) {
	    config->user_other_email = talloc_size (config,
						    sizeof (char *) *
						    (emails_length + 1));
	    for (i = 0; i < emails_length; i++)
		config->user_other_email[i] = talloc_strdup (config->user_other_email,
							     emails[i]);
	    config->user_other_email[i] = NULL;

	    g_strfreev (emails);

	    config->user_other_email_length = emails_length;
	}
    }

    *length = config->user_other_email_length;
    return config->user_other_email;
}

void
notmuch_config_set_user_other_email (notmuch_config_t *config,
				     const char *other_email[],
				     size_t length)
{
    g_key_file_set_string_list (config->key_file,
				"user", "other_email",
				other_email, length);

    talloc_free (config->user_other_email);
    config->user_other_email = NULL;
}

const char **
notmuch_config_get_new_tags (notmuch_config_t *config,
			     size_t *length)
{
    char **tags;
    size_t tags_length;
    unsigned int i;

    if (config->new_tags == NULL) {
	tags = g_key_file_get_string_list (config->key_file,
					   "new", "tags",
					   &tags_length, NULL);
	if (tags) {
	    config->new_tags = talloc_size (config,
					    sizeof (char *) *
					    (tags_length + 1));
	    for (i = 0; i < tags_length; i++)
		config->new_tags[i] = talloc_strdup (config->new_tags,
						     tags[i]);
	    config->new_tags[i] = NULL;

	    g_strfreev (tags);

	    config->new_tags_length = tags_length;
	}
    }

    *length = config->new_tags_length;
    return config->new_tags;
}

void
notmuch_config_set_new_tags (notmuch_config_t *config,
			     const char *new_tags[],
			     size_t length)
{
    g_key_file_set_string_list (config->key_file,
				"new", "tags",
				new_tags, length);

    talloc_free (config->new_tags);
    config->new_tags = NULL;
}

enum notmuch_maildir_sync
notmuch_config_get_maildir_sync (notmuch_config_t *config)
{
    if (config->maildir_sync == NOTMUCH_MAILDIR_SYNC_INVALID) {
	config->maildir_sync = 
	    g_key_file_get_integer (config->key_file,
				    "maildir", "sync_level", NULL);
    }
    return config->maildir_sync;
}

void
notmuch_config_set_maildir_sync (notmuch_config_t *config,
				 enum notmuch_maildir_sync maildir_sync)
{
    g_key_file_set_integer (config->key_file,
			    "maildir", "sync_level", maildir_sync);
    config->maildir_sync = maildir_sync;
}

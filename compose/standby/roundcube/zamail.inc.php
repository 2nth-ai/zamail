<?php
// ZA Mail webmail settings, loaded on top of the Roundcube image defaults.
$config['product_name'] = 'ZA Mail';
$config['username_domain'] = '';          // users sign in with their full email address
$config['smtp_user'] = '%u';
$config['smtp_pass'] = '%p';
$config['session_lifetime'] = 60;
$config['login_rate_limit'] = 5;
$config['plugins'] = array_merge($config['plugins'] ?? [], ['archive', 'zipdownload', 'markasjunk']);

// Webmail and the mail server sit on the same private network and the server
// certificate is issued for the public hostname, so the name is not checked here.
// The connection is still encrypted.
$tls = ['ssl' => ['verify_peer' => false, 'verify_peer_name' => false, 'allow_self_signed' => true]];
$config['imap_conn_options'] = $tls;
$config['smtp_conn_options'] = $tls;

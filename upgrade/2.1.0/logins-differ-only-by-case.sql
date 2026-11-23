-- The accounts users.0020 refuses to lowercase: logins equal under lower(), as Django's Lower() compares them.
SELECT id, username
FROM users_user
WHERE lower(username) IN (
    SELECT lower(username) FROM users_user GROUP BY lower(username) HAVING count(*) > 1
)
ORDER BY lower(username), username;

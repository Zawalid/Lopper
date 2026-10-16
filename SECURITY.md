# Security

Lopper moves files and deletes git branches, so a bug can cost someone work. Treat these as security issues:

- Lopper removing something it should not have (a branch with unmerged work, a symlink target, a folder outside
  the scanned folders).
- A way to make Lopper act outside the folders you chose.
- Anything that sends data off your Mac. Lopper is not supposed to send any.

## Reporting

Please do not open a public issue. Use GitHub's private vulnerability reporting: open the **Security** tab of
this repository and choose **Report a vulnerability**. Include the steps, the Lopper version and your macOS
version. You can expect a first reply within a week.

## Supported versions

Only the latest release receives fixes while Lopper is pre-1.0.

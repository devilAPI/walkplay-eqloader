/// Name, version and links shown on the About page.
library;

const appName = 'Walkplay PEQ Loader';

/// Set by the build workflows (`--dart-define=APP_VERSION=v1.3`, `dev-57`).
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

const repoUrl = 'https://github.com/devilAPI/walkplay-eqloader';
const releasesUrl = '$repoUrl/releases';
const issuesUrl = '$repoUrl/issues';
const webAppUrl = 'https://devilapi.github.io/walkplay-eqloader/';
const autoEqUrl = 'https://github.com/jaakkopasanen/AutoEq';

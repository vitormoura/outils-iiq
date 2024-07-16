
$DebugPreference = 'Continue';

Import-Module ./scripts/IdentityIQ-FunctionsForDev.psm1

Export-IIQRuleFiles -PathJavaFiles "./src/rules/*.java" -OutputDir './temp'
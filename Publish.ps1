
$DebugPreference = 'Continue';

Import-Module ./scripts/IdentityIQ-FunctionsForDev.psm1

if(-not (Test-Path ./temp)) {
	mkdir ./temp
}

Export-IIQRuleFiles -PathJavaFiles "./src/rules/**/*.java" -OutputDir './temp'

@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Script parameters read inside the script's own functions, and
        # variables set in Pester BeforeAll blocks, are reported as unused.
        'PSReviewUnusedParameter',
        'PSUseDeclaredVarsMoreThanAssignments',
        # -WhatIf/-Confirm mean nothing for the private helpers of an
        # unattended script; their names should say what they do.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}

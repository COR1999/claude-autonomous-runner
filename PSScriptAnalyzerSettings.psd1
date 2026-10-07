@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Script parameters read inside the script's own functions, and
        # variables set in Pester BeforeAll blocks, are reported as unused.
        'PSReviewUnusedParameter',
        'PSUseDeclaredVarsMoreThanAssignments'
    )
}

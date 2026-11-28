namespace Wslbin.Tests;

public class SmokeTests
{
    [Fact]
    public void The_program_sources_are_in_the_test_library() =>
        Assert.Equal(@"a\ b", Bash.Smart("a b"));
}

using Acmebot.Options;

using Azure.Functions.Worker.Extensions.HttpApi;

using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Options;

namespace Acmebot.Functions;

public class GetSettings(IHttpContextAccessor httpContextAccessor, IOptions<AcmebotOptions> options) : HttpFunctionBase(httpContextAccessor)
{
    [Function(nameof(GetSettings))]
    public IActionResult HttpStart(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "api/settings")] HttpRequest req)
    {
        if (!User.Identity?.IsAuthenticated ?? false)
        {
            return Unauthorized();
        }

        return Ok(new
        {
            drConfigured = !string.IsNullOrEmpty(options.Value.DrVaultBaseUrl)
        });
    }
}

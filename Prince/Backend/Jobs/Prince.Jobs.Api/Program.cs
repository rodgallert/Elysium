using Hangfire;
using Hangfire.PostgreSql;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;
using Prince.Jobs.Api.Identity;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddOpenApi();
builder.Services.AddHealthChecks();

builder.Services.AddHangfire(config => config
    .SetDataCompatibilityLevel(CompatibilityLevel.Version_180)
    .UseSimpleAssemblyNameTypeSerializer()
    .UseRecommendedSerializerSettings()
    .UsePostgreSqlStorage(options =>
        options.UseNpgsqlConnection(builder.Configuration.GetConnectionString("Prince"))));

builder.Services.AddHangfireServer();

// Admin auth: separate ASP.NET Core Identity store, independent from Core's user auth.
builder.Services.AddDbContext<JobsIdentityDbContext>(options =>
    options.UseNpgsql(builder.Configuration.GetConnectionString("Prince")));

builder.Services
    .AddIdentity<IdentityUser, IdentityRole>()
    .AddEntityFrameworkStores<JobsIdentityDbContext>()
    .AddDefaultTokenProviders();

builder.Services.ConfigureApplicationCookie(options =>
{
    options.Cookie.Name = "Prince.Jobs.Admin";
    options.LoginPath = "/admin/login";
});

builder.Services.AddAuthorization();

var app = builder.Build();

if (app.Environment.IsDevelopment())
{
    app.MapOpenApi();
}

app.UseHttpsRedirection();

app.UseAuthentication();
app.UseAuthorization();

app.MapHealthChecks("/health");

// Hangfire's own local-requests-only filter is disabled — the endpoint-level
// RequireAuthorization() below (backed by the Identity cookie above) is the real gate.
app.MapHangfireDashboard("/hangfire", new DashboardOptions
{
    Authorization = []
}).RequireAuthorization();

app.MapGet("/admin/login", (string? returnUrl, bool? failed) =>
    Results.Content(LoginPage.Render(returnUrl ?? "/hangfire", failed ?? false), "text/html"));

app.MapPost("/admin/login", async (HttpContext httpContext, SignInManager<IdentityUser> signInManager) =>
{
    var form = await httpContext.Request.ReadFormAsync();
    var email = form["email"].ToString();
    var password = form["password"].ToString();
    var returnUrl = string.IsNullOrEmpty(form["returnUrl"].ToString()) ? "/hangfire" : form["returnUrl"].ToString();

    var result = await signInManager.PasswordSignInAsync(email, password, isPersistent: true, lockoutOnFailure: false);

    return result.Succeeded
        ? Results.Redirect(returnUrl)
        : Results.Redirect($"/admin/login?failed=true&returnUrl={Uri.EscapeDataString(returnUrl)}");
});

app.MapPost("/admin/logout", async (SignInManager<IdentityUser> signInManager) =>
{
    await signInManager.SignOutAsync();
    return Results.Redirect("/admin/login");
});

RecurringJob.AddOrUpdate<HeartbeatJob>(
    "heartbeat",
    job => job.Run(),
    Cron.Minutely);

using (var scope = app.Services.CreateScope())
{
    var dbContext = scope.ServiceProvider.GetRequiredService<JobsIdentityDbContext>();
    await dbContext.Database.MigrateAsync();

    var userManager = scope.ServiceProvider.GetRequiredService<UserManager<IdentityUser>>();
    var adminEmail = builder.Configuration["JobsAdmin:Email"] ?? "admin@prince.local";
    var adminPassword = builder.Configuration["JobsAdmin:Password"] ?? "ChangeMe123!";

    if (await userManager.FindByEmailAsync(adminEmail) is null)
    {
        var admin = new IdentityUser { UserName = adminEmail, Email = adminEmail, EmailConfirmed = true };
        await userManager.CreateAsync(admin, adminPassword);
    }
}

app.Run();

public class HeartbeatJob(ILogger<HeartbeatJob> logger)
{
    public void Run() => logger.LogInformation("Prince.Jobs heartbeat at {Timestamp}", DateTimeOffset.UtcNow);
}

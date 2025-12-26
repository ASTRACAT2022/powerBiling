<?php

namespace Poweradmin\Application\Controller;

use Poweradmin\BaseController;
use Poweradmin\Application\Service\UserAuthenticationService;
use Poweradmin\Domain\Model\UserManager;
use Poweradmin\Infrastructure\Configuration\ConfigurationManager;
use Poweradmin\Infrastructure\Database\DatabaseFactory;

class RegisterController extends BaseController
{
    private $db;
    private $userManager;

    public function __construct(array $request = [])
    {
        // Don't authenticate for registration page
        parent::__construct($request, false);
        $this->db = DatabaseFactory::getDatabase();
        $this->userManager = new UserManager($this->db, ConfigurationManager::getInstance());
    }

    public function run(): void
    {
        if (isset($_POST['username'])) {
            $this->processRegistration();
        } else {
            $this->showRegistrationForm();
        }
    }

    private function showRegistrationForm(): void
    {
        // Generate CSRF token if not exists
        if (empty($_SESSION['token'])) {
            $_SESSION['token'] = bin2hex(random_bytes(32));
        }

        $this->render('register.html', [
            'token' => $_SESSION['token']
        ]);
    }

    private function processRegistration(): void
    {
        // Basic CSRF check
        if (!isset($_POST['token']) || $_POST['token'] !== $_SESSION['token']) {
            $this->render('register.html', [
                'error' => 'Invalid security token',
                'token' => $_SESSION['token']
            ]);
            return;
        }

        // Basic validation
        $username = trim($_POST['username'] ?? '');
        $fullname = trim($_POST['fullname'] ?? '');
        $email = trim($_POST['email'] ?? '');
        $password = $_POST['password'] ?? '';
        $passwordConfirm = $_POST['password_confirm'] ?? '';

        if (empty($username) || empty($email) || empty($password)) {
            $this->render('register.html', [
                'error' => 'All fields are required',
                'token' => $_SESSION['token']
            ]);
            return;
        }

        if ($password !== $passwordConfirm) {
            $this->render('register.html', [
                'error' => 'Passwords do not match',
                'token' => $_SESSION['token']
            ]);
            return;
        }

        // Use UserManager to check if user exists
        if (UserManager::userExists($this->db, $username)) {
            $this->render('register.html', [
                'error' => 'Username already exists',
                'token' => $_SESSION['token']
            ]);
            return;
        }

        // Hash password
        $config = ConfigurationManager::getInstance();
        $userAuthService = new UserAuthenticationService(
            $config->get('security', 'password_encryption'),
            $config->get('security', 'password_cost')
        );
        $passwordHash = $userAuthService->hashPassword($password);

        // Get default permission template.
        // ID 1 is Administrator in Poweradmin default schema, which is DANGEROUS for public registration.
        // ID 4 is "Read Only" or ID 5 is "No Access".
        // ID 2 might be "Zone Manager" but usually that's for people managing their own zones.
        // We will look for "Zone Manager" by name, or fallback to "No Access" (ID 5 usually).
        // If neither found, we fallback to a hardcoded safe ID (e.g. 5) or fail.

        // Let's try to find a safe default.
        $safeTemplateId = $this->findSafeTemplateId();

        if ($safeTemplateId === null) {
             $this->render('register.html', [
                'error' => 'Registration unavailable (No public user role found)',
                'token' => $_SESSION['token']
            ]);
            return;
        }

        // Create user
        try {
            // We use the raw insert here because UserManager::addNewUser checks for permissions (user_add_new)
            // which a guest user registering doesn't have.

            $query = "INSERT INTO users (username, password, fullname, email, description, perm_templ, active, use_ldap, auth_method)
                      VALUES (:username, :password, :fullname, :email, :description, :perm_templ, :active, :use_ldap, :auth_method)";

            $stmt = $this->db->prepare($query);
            $stmt->bindValue(':username', $username);
            $stmt->bindValue(':password', $passwordHash);
            $stmt->bindValue(':fullname', $fullname);
            $stmt->bindValue(':email', $email);
            $stmt->bindValue(':description', 'Registered via public registration');
            $stmt->bindValue(':perm_templ', $safeTemplateId);
            $stmt->bindValue(':active', 1); // Active by default
            $stmt->bindValue(':use_ldap', 0);
            $stmt->bindValue(':auth_method', 'sql');

            $stmt->execute();

            // Redirect to login
            header('Location: ' . $this->config->get('interface', 'base_url_prefix', '') . '/login?registered=1');
            exit;

        } catch (\Exception $e) {
             $this->render('register.html', [
                'error' => 'Registration failed: ' . $e->getMessage(),
                'token' => $_SESSION['token']
            ]);
        }
    }

    private function findSafeTemplateId(): ?int
    {
        // Try to find "User" or "Zone Manager" or "Read Only"
        // Order of preference: User > Zone Manager > Read Only
        $preferred = ['User', 'Zone Manager', 'Read Only'];

        foreach ($preferred as $name) {
            $stmt = $this->db->prepare("SELECT id FROM perm_templ WHERE name = :name");
            $stmt->execute([':name' => $name]);
            $id = $stmt->fetchColumn();
            if ($id) return (int)$id;
        }

        // If not found, use getMinimalPermissionTemplateId but ensure it is NOT ID 1 (Admin)
        if (method_exists(UserManager::class, 'getMinimalPermissionTemplateId')) {
            $minId = UserManager::getMinimalPermissionTemplateId($this->db);
            if ($minId && $minId != 1) {
                return $minId;
            }
        }

        return null;
    }
}

<?php

namespace Poweradmin\Application\Controller;

use Poweradmin\BaseController;
use Poweradmin\Application\Utils\SessionManager;
use Poweradmin\Application\Utils\PermissionManager;
use Poweradmin\Domain\Entity\User;
use Poweradmin\Domain\Repository\DomainRepository;
use Poweradmin\Domain\Repository\RecordRepository;
use Poweradmin\Domain\Repository\UserRepository;
use Poweradmin\Infrastructure\Repository\DbZoneRepository;
use Poweradmin\Infrastructure\Repository\DbUserRepository;

class AdminDashboardController extends BaseController
{
    public function run(): void
    {
        if (!PermissionManager::isGodlike()) {
             $this->redirect('/');
             return;
        }

        // Use appropriate repositories
        // Note: DomainRepository is the interface/class in Domain namespace, but DbZoneRepository seems to be the infrastructure implementation
        // For now, let's use the DomainRepository which seems to be the main one used in controllers
        $domainRepo = new DomainRepository($this->db, $this->config);

        // We'll use raw queries for counts if repositories don't support it directly in a clean way
        // or check if DbZoneRepository has better methods.
        // Let's rely on DomainRepository::getZones for the list.

        // Count Zones
        $stmt = $this->db->query("SELECT COUNT(*) FROM domains");
        $totalZones = $stmt->fetchColumn();

        // Count Records
        $stmt = $this->db->query("SELECT COUNT(*) FROM records");
        $totalRecords = $stmt->fetchColumn();

        // Count Users
        $stmt = $this->db->query("SELECT COUNT(*) FROM users");
        $totalUsers = $stmt->fetchColumn();

        // Get Recent Zones
        // DomainRepository::getZones returns an array of zones.
        // We can ask for all zones sorted by id desc to get recent ones.
        $recentZones = $domainRepo->getZones('all', 0, 'all', 0, 5, 'id', 'DESC');

        $templateVars = [
            'current_page' => 'admin_dashboard',
            'iface_title' => 'Admin Control Plane',
            'total_zones' => $totalZones,
            'total_records' => $totalRecords,
            'total_users' => $totalUsers,
            'recent_zones' => $recentZones,
        ];

        $this->render('admin_dashboard.html', $templateVars);
    }
}

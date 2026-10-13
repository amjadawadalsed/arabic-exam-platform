/**
 * منظومة تقييم واختبارات اللغة العربية - Arabic Assessment & Exam Module
 * Main App Controller & Common UI Utilities
 */

import { CONFIG } from './config.js';
import { logout } from './services/auth.js';

/**
 * Initialize common navigation header elements
 */
export function initNavbar({ profile, role }) {
  const tenantBadge = document.getElementById('navbar-tenant-id');
  const userNameEl = document.getElementById('navbar-user-name');
  const userRoleEl = document.getElementById('navbar-user-role');
  const userAvatarEl = document.getElementById('navbar-user-avatar');
  const logoutBtn = document.getElementById('navbar-logout-btn');

  if (tenantBadge) {
    tenantBadge.textContent = profile?.external_tenant_id || CONFIG.DEFAULT_TENANT_ID;
  }

  if (userNameEl) {
    userNameEl.textContent = profile?.full_name || profile?.email || (role === 'teacher' ? 'معلم' : 'طالب');
  }

  if (userRoleEl) {
    if (role === 'teacher') {
      userRoleEl.textContent = 'معلم / مصحح';
    } else if (role === 'admin') {
      userRoleEl.textContent = 'مشرف النظام';
    } else {
      userRoleEl.textContent = 'طالب';
    }
  }

  if (userAvatarEl) {
    const name = profile?.full_name || profile?.email || 'م';
    userAvatarEl.textContent = name.trim().charAt(0).toUpperCase();
  }

  if (logoutBtn) {
    logoutBtn.addEventListener('click', (e) => {
      e.preventDefault();
      logout();
    });
  }
}

/**
 * Format ISO date string into friendly Arabic date
 */
export function formatDate(isoString) {
  if (!isoString) return '—';
  try {
    const date = new Date(isoString);
    return new Intl.DateTimeFormat('ar-EG', {
      year: 'numeric',
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    }).format(date);
  } catch (e) {
    return isoString;
  }
}

/**
 * Format Exam Type into Arabic
 */
export function formatExamType(type) {
  switch (type) {
    case 'placement':
      return 'تحديد مستوى';
    case 'formative':
      return 'تقييم تكويني';
    case 'summative':
      return 'تقييم ختامي';
    case 'diagnostic':
      return 'تشخيصي';
    default:
      return type || 'عام';
  }
}

/**
 * Format Attempt Status Badge with correct localized Arabic text and class
 * Uses valid backend statuses: in_progress, completed, expired.
 */
export function formatStatusBadge(status, finalScoringStatus = null) {
  if (status === 'in_progress') {
    return '<span class="badge badge-info">قيد التنفيذ</span>';
  }
  if (status === 'expired') {
    return '<span class="badge badge-danger">منتهي الصلاحية</span>';
  }
  if (status === 'completed') {
    if (finalScoringStatus === 'provisional') {
      return '<span class="badge badge-warning">مكتمل (بانتظار اعتماد المعلم)</span>';
    }
    if (finalScoringStatus === 'official_final') {
      return '<span class="badge badge-success">معتمد نهائياً</span>';
    }
    return '<span class="badge badge-primary">مكتمل</span>';
  }
  return `<span class="badge badge-neutral">${status || 'غير معروف'}</span>`;
}

/**
 * Format Passing Status
 */
export function formatPassStatus(isPassed) {
  if (isPassed === true) {
    return '<span class="badge badge-success">اجتياز (ناجح)</span>';
  }
  if (isPassed === false) {
    return '<span class="badge badge-danger">لم يجتز</span>';
  }
  return '<span class="badge badge-warning">معلق</span>';
}

/**
 * Format duration in minutes
 */
export function formatDuration(minutes) {
  if (!minutes) return '—';
  return `${minutes} دقيقة`;
}

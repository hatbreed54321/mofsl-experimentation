import { RequestHandler } from 'express';
import jwt from 'jsonwebtoken';
import { config } from '../config';
import { UnauthorizedError } from '../utils/errors';

export interface AuthenticatedUser {
  id: string;
  email: string;
  role: string;
}

// Extend Express Request to carry the authenticated user
declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Express {
    interface Request {
      user?: AuthenticatedUser;
    }
  }
}

/**
 * JWT authentication middleware for dashboard/control-plane routes.
 *
 * Expects: Authorization: Bearer <jwt>
 *
 * In Phase 6 (development), the JWT is signed with JWT_SECRET from .env.
 * Phase 8 will add full MOFSL SSO (SAML/OIDC) integration — the token shape
 * and validation will move to auth.service.ts.
 *
 * For local dev/testing, generate a token with:
 *   node -e "console.log(require('jsonwebtoken').sign(
 *     { sub: 'dev-user-id', email: 'dev@mofsl.com', role: 'admin' },
 *     process.env.JWT_SECRET, { expiresIn: '8h' }
 *   ))"
 */
export const requireAuth: RequestHandler = (req, _res, next) => {
  const authHeader = req.headers.authorization;

  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return next(new UnauthorizedError('Authorization header with Bearer token is required'));
  }

  const token = authHeader.slice(7);

  try {
    const payload = jwt.verify(token, config.jwtSecret) as {
      sub: string;
      email: string;
      role: string;
    };

    req.user = {
      id: payload.sub,
      email: payload.email,
      role: payload.role ?? 'admin',
    };

    return next();
  } catch {
    return next(new UnauthorizedError('Invalid or expired token'));
  }
};

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title KipuBankV2
/// @notice Banco multi-token (ETH y ERC-20) con control de acceso, oráculo Chainlink y contabilidad en USDC (6 decimales).


import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract KipuBankV2 is AccessControl {
    // ============================
    // Roles y constantes
    // ============================

    /// @notice Rol administrativo para registrar tokens y operar funciones restringidas.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Oráculo ETH/USD (Chainlink). Inmutable tras el despliegue.
    AggregatorV3Interface public immutable priceFeed;

    /// @notice Límite global del banco expresado en USDC (6 decimales).
    uint256 public constant BANK_CAP_USD = 100_000 * 1e6;

    // ============================
    // Estado y contabilidad
    // ============================

    /// @notice Mapeo de balances: usuario => token => cantidad.
    /// @dev address(0) representa Ether.
    mapping(address => mapping(address => uint256)) public balances;

    /// @notice Decimales de cada token registrado.
    mapping(address => uint8) public tokenDecimals;

    /// @notice Total del banco contabilizado en USDC (6 decimales). Se actualiza con depósitos/retiros de ETH.
    uint256 public totalBankUSD;

    // ============================
    // Eventos
    // ============================

    /// @notice Emite cuando se registra un token ERC-20.
    event TokenRegistrado(address indexed token, uint8 decimals);

    /// @notice Emite en cada depósito.
    event Deposito(address indexed usuario, address indexed token, uint256 monto);

    /// @notice Emite en cada retiro.
    event Retiro(address indexed usuario, address indexed token, uint256 monto);

    /// @notice Emite cuando un depósito intentaría superar el cap del banco.
    event BankCapReached(uint256 attemptedUsd, uint256 bankCapUsd);

    // ============================
    // Errores personalizados
    // ============================

    /// @notice Lanzado si se intenta operar con monto cero.
    error MontoCero();

    /// @notice Lanzado si el token no está registrado.
    error TokenNoRegistrado();

    /// @notice Lanzado si la operación excede el saldo disponible.
    error SaldoInsuficiente();

    /// @notice Lanzado si el depósito excede el límite global del banco.
    error BankCapExceeded(uint256 attemptedUsd, uint256 bankCapUsd);

    /// @notice Lanzado si una transferencia nativa o ERC-20 falla.
    error TransferFailed();

    // ============================
    // Modificadores
    // ============================

    /// @notice Verifica que el monto sea mayor a cero.
    /// @param monto Cantidad a verificar.
    modifier montoNoCero(uint256 monto) {
        if (monto == 0) revert MontoCero();
        _;
    }

    // ============================
    // Constructor
    // ============================

    /// @notice Inicializa el contrato con el oráculo ETH/USD.
    /// @param _priceFeed Dirección del AggregatorV3Interface de Chainlink para ETH/USD.
    /// @dev Valida que el oráculo no sea address(0).
    constructor(address _priceFeed) {
        if (_priceFeed == address(0)) revert("priceFeed invalido");
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        priceFeed = AggregatorV3Interface(_priceFeed);
    }

    // ============================
    // Administración
    // ============================

    /// @notice Registra un token ERC-20 con sus decimales.
    /// @param token Dirección del token.
    /// @param decimals_ Cantidad de decimales del token.
    /// @dev Requiere ADMIN_ROLE.
    function registrarToken(address token, uint8 decimals_) external onlyRole(ADMIN_ROLE) {
        if (token == address(0)) revert("token invalido");
        tokenDecimals[token] = decimals_;
        emit TokenRegistrado(token, decimals_);
    }

    // ============================
    // Depósitos
    // ============================

    /// @notice Deposita Ether enviando valor en la transacción.
    /// @dev Reutiliza el modificador para evitar msg.value == 0.
    function depositarEther() external payable montoNoCero(msg.value) {
        _depositarETH(msg.sender, msg.value);
    }

    /// @notice Deposita un token ERC-20 previamente registrado.
    /// @param token Dirección del token.
    /// @param monto Cantidad a depositar (en decimales del token).
    function depositarToken(address token, uint256 monto) external montoNoCero(monto) {
        if (tokenDecimals[token] == 0) revert TokenNoRegistrado();

        bool ok = IERC20(token).transferFrom(msg.sender, address(this), monto);
        if (!ok) revert TransferFailed();

        balances[msg.sender][token] += monto;
        emit Deposito(msg.sender, token, monto);
    }

    // ============================
    // Retiros
    // ============================

    /// @notice Retira Ether previamente depositado.
    /// @param monto Cantidad en wei a retirar.
    function retirarEther(uint256 monto) external montoNoCero(monto) {
        uint256 saldoActual = balances[msg.sender][address(0)];
        if (saldoActual < monto) revert SaldoInsuficiente();

        balances[msg.sender][address(0)] -= monto;

        uint256 usdValue = _ethToUsdInUSDC(monto);
        if (totalBankUSD > usdValue) {
            totalBankUSD -= usdValue;
        } else {
            totalBankUSD = 0;
        }

        (bool sent, ) = payable(msg.sender).call{value: monto}("");
        if (!sent) revert TransferFailed();

        emit Retiro(msg.sender, address(0), monto);
    }

    /// @notice Retira un token ERC-20 previamente depositado.
    /// @param token Dirección del token.
    /// @param monto Cantidad a retirar (en decimales del token).
    function retirarToken(address token, uint256 monto) external montoNoCero(monto) {
        uint256 saldoActual = balances[msg.sender][token];
        if (saldoActual < monto) revert SaldoInsuficiente();
        if (tokenDecimals[token] == 0) revert TokenNoRegistrado();

        balances[msg.sender][token] -= monto;

        bool ok = IERC20(token).transfer(msg.sender, monto);
        if (!ok) revert TransferFailed();

        emit Retiro(msg.sender, token, monto);
    }

    // ============================
    // Consultas
    // ============================

    /// @notice Obtiene el precio ETH/USD desde el oráculo Chainlink.
    /// @return precio Valor del precio con los decimales del feed (comúnmente 8).
    function obtenerPrecioETHUSD() public view returns (uint256 precio) {
        (, int256 answer, , , ) = priceFeed.latestRoundData();
        require(answer > 0, "precio no disponible");
        precio = uint256(answer);
    }

    /// @notice Convierte un monto desde decimales del token a decimales USDC (6).
    /// @param monto Cantidad original.
    /// @param decimalesToken Decimales del token.
    /// @return montoUSDC Monto normalizado a 6 decimales.
    function convertirADecimalesUSDC(uint256 monto, uint8 decimalesToken) public pure returns (uint256 montoUSDC) {
        if (decimalesToken > 6) {
            uint256 factor = 10 ** (uint256(decimalesToken) - 6);
            montoUSDC = monto / factor;
        } else {
            uint256 factor = 10 ** (6 - uint256(decimalesToken));
            montoUSDC = monto * factor;
        }
    }

    // ============================
    // Internas
    // ============================

    /// @notice Lógica común de depósito de Ether, actualiza contabilidad y verifica el cap.
    /// @param usuario Dirección que deposita.
    /// @param monto Cantidad en wei.
    function _depositarETH(address usuario, uint256 monto) internal {
        // CEI: Checks
        uint256 usdValue = _ethToUsdInUSDC(monto);
        uint256 nuevoTotal = totalBankUSD + usdValue;
        if (nuevoTotal > BANK_CAP_USD) {
            emit BankCapReached(nuevoTotal, BANK_CAP_USD);
            revert BankCapExceeded(nuevoTotal, BANK_CAP_USD);
        }

        // Effects
        balances[usuario][address(0)] += monto;
        totalBankUSD = nuevoTotal;

        // Interactions: no hay llamadas externas aquí
        emit Deposito(usuario, address(0), monto);
    }

    /// @notice Convierte montos de ETH (wei) a USD en formato USDC (6 decimales).
    /// @param weiAmount Cantidad en wei.
    /// @return usd6 Valor equivalente en USD con 6 decimales.
    function _ethToUsdInUSDC(uint256 weiAmount) internal view returns (uint256 usd6) {
        uint256 price = obtenerPrecioETHUSD(); // típicamente 8 decimales
        // usd (con decimales del feed) = (weiAmount * price) / 1e18
        uint256 usdFeedDecimals = (weiAmount * price) / 1e18;
        // Ajuste 8 -> 6 decimales (asumiendo feed de 8 decimales)
        usd6 = usdFeedDecimals / 100;
    }

    // ============================
    // Recepción directa de ETH
    // ============================

    /// @notice Permite recibir ETH directamente y contabilizarlo como depósito.
    /// @dev Delegamos en la misma lógica de depósitos.
    receive() external payable {
        if (msg.value == 0) revert MontoCero();
        _depositarETH(msg.sender, msg.value);
    }

    /// @notice Fallback que acepta ETH y lo trata como depósito si trae valor.
    fallback() external payable {
        if (msg.value > 0) {
            _depositarETH(msg.sender, msg.value);
        }
    }
}
